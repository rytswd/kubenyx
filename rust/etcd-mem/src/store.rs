// In-memory etcd-compatible KV store.
//
// Semantics that kube-apiserver depends on:
// - Global revision increments once per mutating operation (Txn counts as one).
// - Range uses half-open [key, range_end) matching; "\x00" means "open end".
// - Watch delivers events from start_revision+1 onward with no gaps.
// - Leases: keys attached to an expired lease are deleted in a background task.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::broadcast;
use tokio::sync::Mutex;

pub const CLUSTER_ID: u64 = 0xCAFE_DEAD_BEEF_0001;
pub const MEMBER_ID: u64 = 1;

// ─── core types ──────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct Kv {
    pub key:             Vec<u8>,
    pub value:           Vec<u8>,
    pub create_revision: i64,
    pub mod_revision:    i64,
    pub version:         i64,
    pub lease:           i64,
}

#[derive(Clone, Debug)]
pub struct StoredEvent {
    pub ev_type:          i32, // 0=PUT 1=DELETE
    pub kv:               Kv,
    pub prev_kv:          Option<Kv>,
}

#[derive(Clone, Debug)]
pub struct BroadcastBatch {
    pub revision: i64,
    pub events:   Vec<StoredEvent>,
}

#[derive(Clone, Debug)]
pub struct LeaseEntry {
    pub id:          i64,
    pub granted_ttl: i64,
    pub deadline:    Instant,
    pub keys:        Vec<Vec<u8>>,
}

// ─── store ───────────────────────────────────────────────────────────────────

pub struct Store {
    pub kvs:              BTreeMap<Vec<u8>, Kv>,
    pub revision:         i64,
    pub compact_revision: i64,
    // Full event log kept — volatile cluster, memory is cheap vs correctness.
    pub log:              Vec<(i64, Vec<StoredEvent>)>, // (revision, events_at_rev)
    pub leases:           BTreeMap<i64, LeaseEntry>,
    pub next_lease_id:    i64,
    tx:                   broadcast::Sender<BroadcastBatch>,
}

pub type SharedStore = Arc<Mutex<Store>>;

impl Store {
    pub fn new() -> (SharedStore, broadcast::Receiver<BroadcastBatch>) {
        let (tx, rx) = broadcast::channel(8192);
        let store = Store {
            kvs:              BTreeMap::new(),
            // Real etcd's initial revision is 1 (first mutation gets rev 2).
            // Starting at 0 makes empty Ranges return header.revision=0,
            // which kube-apiserver rejects ("illegal resource version from
            // storage: 0"); RBAC bootstrap then fails and the
            // bootstrap-system-priority-classes PostStartHook klog.Fatals
            // the apiserver into a restart loop.
            revision:         1,
            compact_revision: 0,
            log:              Vec::new(),
            leases:           BTreeMap::new(),
            next_lease_id:    1,
            tx,
        };
        (Arc::new(Mutex::new(store)), rx)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<BroadcastBatch> {
        self.tx.subscribe()
    }

    pub fn header_rev(&self, revision: i64) -> crate::etcd::ResponseHeader {
        crate::etcd::ResponseHeader {
            cluster_id: CLUSTER_ID,
            member_id:  MEMBER_ID,
            revision,
            raft_term:  1,
        }
    }
    pub fn header(&self) -> crate::etcd::ResponseHeader {
        self.header_rev(self.revision)
    }

    // ── range helpers ──────────────────────────────────────────────────────

    fn in_range(key: &[u8], req_key: &[u8], range_end: &[u8]) -> bool {
        if range_end.is_empty() {
            return key == req_key;
        }
        // "\x00" is the sentinel "all keys ≥ req_key"
        if range_end == b"\x00" {
            return key >= req_key;
        }
        key >= req_key && key < range_end
    }

    pub fn range_kvs(
        &self,
        req_key:   &[u8],
        range_end: &[u8],
        limit:     i64,
        rev:       i64,
        min_mod:   i64,
        max_mod:   i64,
        min_create:i64,
        max_create:i64,
    ) -> (Vec<Kv>, bool, i64) {
        // Clamp the revision to what we actually have.
        let at_rev = if rev == 0 { self.revision } else { rev.min(self.revision) };

        // Walk BTreeMap in ascending key order.
        let all: Vec<&Kv> = if range_end.is_empty() {
            self.kvs.get(req_key).into_iter().collect()
        } else if range_end == b"\x00" {
            self.kvs.range(req_key.to_vec()..).map(|(_, v)| v).collect()
        } else {
            self.kvs
                .range(req_key.to_vec()..range_end.to_vec())
                .map(|(_, v)| v)
                .collect()
        };

        // Filter: only keys whose mod_revision ≤ at_rev and pass the
        // rev-range filters requested by the apiserver.
        let filtered: Vec<&Kv> = all
            .into_iter()
            .filter(|kv| {
                kv.mod_revision <= at_rev
                    && (min_mod == 0 || kv.mod_revision >= min_mod)
                    && (max_mod == 0 || kv.mod_revision <= max_mod)
                    && (min_create == 0 || kv.create_revision >= min_create)
                    && (max_create == 0 || kv.create_revision <= max_create)
            })
            .collect();

        let total = filtered.len() as i64;
        let lim = if limit <= 0 { usize::MAX } else { limit as usize };
        let more = filtered.len() > lim;
        let kvs: Vec<Kv> = filtered.into_iter().take(lim).cloned().collect();
        (kvs, more, total)
    }

    // ── mutations ──────────────────────────────────────────────────────────

    pub fn put(
        &mut self,
        key:          Vec<u8>,
        value:        Vec<u8>,
        lease:        i64,
        want_prev_kv: bool,
        ignore_value: bool,
        ignore_lease: bool,
    ) -> (crate::etcd::ResponseHeader, Option<Kv>) {
        self.revision += 1;
        let rev = self.revision;

        let prev = self.kvs.get(&key).cloned();

        let use_value = if ignore_value {
            prev.as_ref().map(|k| k.value.clone()).unwrap_or_default()
        } else {
            value
        };
        let use_lease = if ignore_lease {
            prev.as_ref().map(|k| k.lease).unwrap_or(0)
        } else {
            lease
        };

        // Update old lease's key list.
        if let Some(old_lease) = prev.as_ref().map(|k| k.lease).filter(|&l| l != 0) {
            if let Some(le) = self.leases.get_mut(&old_lease) {
                le.keys.retain(|k| k != &key);
            }
        }
        // Register key under new lease.
        if use_lease != 0 {
            if let Some(le) = self.leases.get_mut(&use_lease) {
                if !le.keys.contains(&key) {
                    le.keys.push(key.clone());
                }
            }
        }

        let entry = Kv {
            key:             key.clone(),
            value:           use_value,
            create_revision: prev.as_ref().map(|k| k.create_revision).unwrap_or(rev),
            mod_revision:    rev,
            version:         prev.as_ref().map(|k| k.version + 1).unwrap_or(1),
            lease:           use_lease,
        };

        let ev = StoredEvent {
            ev_type: 0,
            kv:      entry.clone(),
            prev_kv: prev.clone(),
        };
        self.kvs.insert(key, entry);
        self.emit(rev, vec![ev]);

        (self.header(), if want_prev_kv { prev } else { None })
    }

    pub fn delete_range(
        &mut self,
        req_key:      &[u8],
        range_end:    &[u8],
        want_prev_kv: bool,
    ) -> (crate::etcd::ResponseHeader, i64, Vec<Kv>) {
        let keys: Vec<Vec<u8>> = if range_end.is_empty() {
            self.kvs.contains_key(req_key).then(|| vec![req_key.to_vec()]).unwrap_or_default()
        } else if range_end == b"\x00" {
            self.kvs.range(req_key.to_vec()..).map(|(k, _)| k.clone()).collect()
        } else {
            self.kvs
                .range(req_key.to_vec()..range_end.to_vec())
                .map(|(k, _)| k.clone())
                .collect()
        };

        if keys.is_empty() {
            return (self.header(), 0, vec![]);
        }

        self.revision += 1;
        let rev = self.revision;
        let mut prev_kvs = Vec::new();
        let mut events = Vec::new();

        for k in &keys {
            if let Some(old) = self.kvs.remove(k) {
                // Deregister from lease.
                if old.lease != 0 {
                    if let Some(le) = self.leases.get_mut(&old.lease) {
                        le.keys.retain(|lk| lk != k);
                    }
                }
                let del_kv = Kv {
                    key:             k.clone(),
                    value:           vec![],
                    create_revision: old.create_revision,
                    mod_revision:    rev,
                    version:         0,
                    lease:           0,
                };
                events.push(StoredEvent {
                    ev_type: 1,
                    kv:      del_kv,
                    prev_kv: Some(old.clone()),
                });
                if want_prev_kv { prev_kvs.push(old); }
            }
        }

        let deleted = events.len() as i64;
        self.emit(rev, events);
        (self.header(), deleted, prev_kvs)
    }

    // ── transactions ───────────────────────────────────────────────────────

    pub fn txn(
        &mut self,
        req: &crate::etcd::TxnRequest,
    ) -> (crate::etcd::ResponseHeader, bool, Vec<crate::etcd::ResponseOp>) {
        let ok = req.compare.iter().all(|c| self.eval_compare(c));
        let ops = if ok { &req.success } else { &req.failure };
        let responses = ops.iter().map(|op| self.exec_op(op)).collect();
        // Header uses the revision AFTER any mutations in exec_op.
        (self.header(), ok, responses)
    }

    fn eval_compare(&self, c: &crate::etcd::Compare) -> bool {
        use crate::etcd::compare::CompareResult as R;
        use crate::etcd::compare::CompareTarget as T;
        use crate::etcd::compare::TargetUnion;

        let kv = self.kvs.get(&c.key);
        let result = match c.result {
            r if r == R::Equal as i32    => std::cmp::Ordering::Equal,
            r if r == R::Greater as i32  => std::cmp::Ordering::Greater,
            r if r == R::Less as i32     => std::cmp::Ordering::Less,
            _                            => std::cmp::Ordering::Equal, // NOT_EQUAL handled below
        };
        let not_equal = c.result == R::NotEqual as i32;

        match c.target {
            t if t == T::Version as i32 => {
                let v = kv.map(|k| k.version).unwrap_or(0);
                let target = match &c.target_union {
                    Some(TargetUnion::Version(x)) => *x,
                    _ => 0,
                };
                let ord = v.cmp(&target);
                if not_equal { ord != std::cmp::Ordering::Equal } else { ord == result }
            }
            t if t == T::Create as i32 => {
                let v = kv.map(|k| k.create_revision).unwrap_or(0);
                let target = match &c.target_union {
                    Some(TargetUnion::CreateRevision(x)) => *x,
                    _ => 0,
                };
                let ord = v.cmp(&target);
                if not_equal { ord != std::cmp::Ordering::Equal } else { ord == result }
            }
            t if t == T::Mod as i32 => {
                let v = kv.map(|k| k.mod_revision).unwrap_or(0);
                let target = match &c.target_union {
                    Some(TargetUnion::ModRevision(x)) => *x,
                    _ => 0,
                };
                let ord = v.cmp(&target);
                if not_equal { ord != std::cmp::Ordering::Equal } else { ord == result }
            }
            t if t == T::Value as i32 => {
                let v = kv.map(|k| k.value.as_slice()).unwrap_or(&[]);
                let target = match &c.target_union {
                    Some(TargetUnion::Value(x)) => x.as_slice(),
                    _ => &[],
                };
                let ord = v.cmp(target);
                if not_equal { ord != std::cmp::Ordering::Equal } else { ord == result }
            }
            t if t == T::Lease as i32 => {
                let v = kv.map(|k| k.lease).unwrap_or(0);
                let target = match &c.target_union {
                    Some(TargetUnion::Lease(x)) => *x,
                    _ => 0,
                };
                let ord = v.cmp(&target);
                if not_equal { ord != std::cmp::Ordering::Equal } else { ord == result }
            }
            _ => true,
        }
    }

    fn exec_op(&mut self, op: &crate::etcd::RequestOp) -> crate::etcd::ResponseOp {
        use crate::etcd::request_op::Request;
        use crate::etcd::response_op::Response;

        match &op.request {
            Some(Request::RequestRange(r)) => {
                let (kvs, more, count) = self.range_kvs(
                    &r.key, &r.range_end, r.limit, r.revision,
                    r.min_mod_revision, r.max_mod_revision,
                    r.min_create_revision, r.max_create_revision,
                );
                let (kvs, count) = if r.count_only {
                    (vec![], count)
                } else {
                    let out = kvs.into_iter().map(|k| kv_to_proto(k, r.keys_only)).collect();
                    (out, count)
                };
                crate::etcd::ResponseOp {
                    response: Some(Response::ResponseRange(crate::etcd::RangeResponse {
                        header: Some(self.header()),
                        kvs,
                        more,
                        count,
                    })),
                }
            }
            Some(Request::RequestPut(r)) => {
                let (hdr, prev) = self.put(
                    r.key.clone(), r.value.clone(), r.lease,
                    r.prev_kv, r.ignore_value, r.ignore_lease,
                );
                crate::etcd::ResponseOp {
                    response: Some(Response::ResponsePut(crate::etcd::PutResponse {
                        header:  Some(hdr),
                        prev_kv: prev.map(|k| kv_to_proto(k, false)),
                    })),
                }
            }
            Some(Request::RequestDeleteRange(r)) => {
                let (hdr, deleted, prev_kvs) =
                    self.delete_range(&r.key, &r.range_end, r.prev_kv);
                crate::etcd::ResponseOp {
                    response: Some(Response::ResponseDeleteRange(crate::etcd::DeleteRangeResponse {
                        header:   Some(hdr),
                        deleted,
                        prev_kvs: prev_kvs.into_iter().map(|k| kv_to_proto(k, false)).collect(),
                    })),
                }
            }
            Some(Request::RequestTxn(r)) => {
                let (hdr, ok, resp) = self.txn(r);
                crate::etcd::ResponseOp {
                    response: Some(Response::ResponseTxn(crate::etcd::TxnResponse {
                        header:    Some(hdr),
                        succeeded: ok,
                        responses: resp,
                    })),
                }
            }
            None => crate::etcd::ResponseOp { response: None },
        }
    }

    // ── compaction ─────────────────────────────────────────────────────────

    pub fn compact(&mut self, compact_rev: i64) -> crate::etcd::ResponseHeader {
        if compact_rev > self.compact_revision {
            self.compact_revision = compact_rev;
            // Evict log entries with revision ≤ compact_rev.
            self.log.retain(|(rev, _)| *rev > compact_rev);
        }
        self.header()
    }

    // ── leases ─────────────────────────────────────────────────────────────

    pub fn lease_grant(&mut self, ttl: i64, id: i64) -> (crate::etcd::ResponseHeader, i64, i64) {
        let actual_id = if id == 0 {
            let next = self.next_lease_id;
            self.next_lease_id += 1;
            next
        } else {
            id
        };
        let actual_ttl = ttl.max(1);
        self.leases.insert(actual_id, LeaseEntry {
            id:          actual_id,
            granted_ttl: actual_ttl,
            deadline:    Instant::now() + Duration::from_secs(actual_ttl as u64),
            keys:        vec![],
        });
        (self.header(), actual_id, actual_ttl)
    }

    pub fn lease_revoke(&mut self, id: i64) -> crate::etcd::ResponseHeader {
        if let Some(le) = self.leases.remove(&id) {
            let keys: Vec<Vec<u8>> = le.keys;
            for k in keys {
                self.delete_range(&k, &[], false);
            }
        }
        self.header()
    }

    pub fn lease_keepalive(&mut self, id: i64) -> Option<(crate::etcd::ResponseHeader, i64, i64)> {
        // Separate the mutable borrow from the immutable self.header() call.
        let granted_ttl = self.leases.get_mut(&id).map(|le| {
            le.deadline = Instant::now() + Duration::from_secs(le.granted_ttl as u64);
            le.granted_ttl
        })?;
        Some((self.header(), id, granted_ttl))
    }

    pub fn lease_ttl(&self, id: i64, want_keys: bool) -> Option<(crate::etcd::ResponseHeader, i64, i64, Vec<Vec<u8>>)> {
        let le = self.leases.get(&id)?;
        let remaining = le.deadline.saturating_duration_since(Instant::now()).as_secs() as i64;
        let keys = if want_keys { le.keys.clone() } else { vec![] };
        // le is no longer used after this point; NLL ends the borrow.
        Some((self.header(), id, remaining, keys))
    }

    pub fn lease_list(&self) -> Vec<i64> {
        self.leases.keys().copied().collect()
    }

    // Returns the set of expired leases (caller should call lease_revoke on each).
    pub fn expired_leases(&self) -> Vec<i64> {
        let now = Instant::now();
        self.leases.values()
            .filter(|le| le.deadline <= now)
            .map(|le| le.id)
            .collect()
    }

    // ── watch log ──────────────────────────────────────────────────────────

    pub fn events_since(&self, start_rev: i64) -> Vec<(i64, Vec<StoredEvent>)> {
        self.log.iter()
            .filter(|(rev, _)| *rev > start_rev)
            .cloned()
            .collect()
    }

    fn emit(&mut self, rev: i64, events: Vec<StoredEvent>) {
        self.log.push((rev, events.clone()));
        let _ = self.tx.send(BroadcastBatch { revision: rev, events });
    }
}

// ── helper ────────────────────────────────────────────────────────────────

pub fn kv_to_proto(k: Kv, keys_only: bool) -> crate::etcd::KeyValue {
    crate::etcd::KeyValue {
        key:             k.key,
        value:           if keys_only { vec![] } else { k.value },
        create_revision: k.create_revision,
        mod_revision:    k.mod_revision,
        version:         k.version,
        lease:           k.lease,
    }
}

pub fn kv_to_event(ev: &StoredEvent) -> crate::etcd::Event {
    crate::etcd::Event {
        r#type:  ev.ev_type,
        kv:      Some(kv_to_proto(ev.kv.clone(), false)),
        prev_kv: ev.prev_kv.as_ref().map(|k| kv_to_proto(k.clone(), false)),
    }
}
