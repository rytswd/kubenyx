// gRPC service implementations wrapping the in-memory store.
use std::pin::Pin;
use tokio_stream::Stream;
use tonic::{Request, Response, Status, Streaming};

use crate::etcd::*;
use crate::etcd::kv_server::Kv as KvTrait;
use crate::etcd::watch_server::Watch as WatchTrait;
use crate::etcd::lease_server::Lease as LeaseTrait;
use crate::etcd::cluster_server::Cluster as ClusterTrait;
use crate::etcd::maintenance_server::Maintenance as MaintenanceTrait;
use crate::store::{kv_to_event, kv_to_proto, SharedStore};

// ────────────────────────────────── KV ─────────────────────────────────────

pub struct KvSvc(pub SharedStore);

#[tonic::async_trait]
impl KvTrait for KvSvc {
    async fn range(
        &self,
        req: Request<RangeRequest>,
    ) -> Result<Response<RangeResponse>, Status> {
        let r = req.into_inner();
        let store = self.0.lock().await;
        let (kvs_raw, more, count) = store.range_kvs(
            &r.key, &r.range_end, r.limit, r.revision,
            r.min_mod_revision, r.max_mod_revision,
            r.min_create_revision, r.max_create_revision,
        );
        let (kvs, count) = if r.count_only {
            (vec![], count)
        } else {
            let out = kvs_raw.into_iter()
                .map(|k| kv_to_proto(k, r.keys_only))
                .collect();
            (out, count)
        };
        Ok(Response::new(RangeResponse {
            header: Some(store.header()),
            kvs,
            more,
            count,
        }))
    }

    async fn put(
        &self,
        req: Request<PutRequest>,
    ) -> Result<Response<PutResponse>, Status> {
        let r = req.into_inner();
        let mut store = self.0.lock().await;
        let (hdr, prev) = store.put(
            r.key, r.value, r.lease, r.prev_kv, r.ignore_value, r.ignore_lease,
        );
        Ok(Response::new(PutResponse {
            header:  Some(hdr),
            prev_kv: prev.map(|k| kv_to_proto(k, false)),
        }))
    }

    async fn delete_range(
        &self,
        req: Request<DeleteRangeRequest>,
    ) -> Result<Response<DeleteRangeResponse>, Status> {
        let r = req.into_inner();
        let mut store = self.0.lock().await;
        let (hdr, deleted, prev_kvs) = store.delete_range(&r.key, &r.range_end, r.prev_kv);
        Ok(Response::new(DeleteRangeResponse {
            header:   Some(hdr),
            deleted,
            prev_kvs: prev_kvs.into_iter().map(|k| kv_to_proto(k, false)).collect(),
        }))
    }

    async fn txn(
        &self,
        req: Request<TxnRequest>,
    ) -> Result<Response<TxnResponse>, Status> {
        let r = req.into_inner();
        let mut store = self.0.lock().await;
        let (hdr, ok, responses) = store.txn(&r);
        Ok(Response::new(TxnResponse {
            header:    Some(hdr),
            succeeded: ok,
            responses,
        }))
    }

    async fn compact(
        &self,
        req: Request<CompactionRequest>,
    ) -> Result<Response<CompactionResponse>, Status> {
        let r = req.into_inner();
        let mut store = self.0.lock().await;
        let hdr = store.compact(r.revision);
        Ok(Response::new(CompactionResponse { header: Some(hdr) }))
    }
}

// ─────────────────────────────── Watch ─────────────────────────────────────

pub struct WatchSvc(pub SharedStore);

// Per-stream watch state.
struct WatchHandle {
    id:               i64,
    key:              Vec<u8>,
    range_end:        Vec<u8>,
    prev_kv:          bool,
    // filters: 0=NOPUT 1=NODELETE; store as bitmask
    filter:           u32,
    // Highest revision already delivered — broadcast events with rev ≤ this
    // are skipped to avoid duplicate delivery after history replay.
    delivered_through: i64,
}

impl WatchHandle {
    fn matches(&self, ev_type: i32, kv: &crate::store::Kv) -> bool {
        // Filter: NOPUT bit=1 means skip PUTs; NODELETE bit=2 means skip DELETEs
        if self.filter & 1 != 0 && ev_type == 0 { return false; }
        if self.filter & 2 != 0 && ev_type == 1 { return false; }
        // Key range check
        if self.range_end.is_empty() {
            kv.key == self.key
        } else if self.range_end == b"\x00" {
            kv.key >= self.key
        } else {
            kv.key >= self.key && kv.key < self.range_end
        }
    }
}

type WatchStream = Pin<Box<dyn Stream<Item = Result<WatchResponse, Status>> + Send>>;

#[tonic::async_trait]
impl WatchTrait for WatchSvc {
    type WatchStream = WatchStream;

    async fn watch(
        &self,
        req: Request<Streaming<WatchRequest>>,
    ) -> Result<Response<Self::WatchStream>, Status> {
        let store_arc = self.0.clone();
        let mut inbound = req.into_inner();

        let (tx, rx) = tokio::sync::mpsc::channel::<Result<WatchResponse, Status>>(256);

        tokio::spawn(async move {
            let mut handles: Vec<WatchHandle> = Vec::new();
            let mut next_watch_id: i64 = 1;
            let mut bcast = {
                let store = store_arc.lock().await;
                store.subscribe()
            };

            loop {
                tokio::select! {
                    // Client message: create/cancel watch
                    msg = inbound.message() => {
                        match msg {
                            Ok(Some(wr)) => {
                                match wr.request_union {
                                    Some(watch_request::RequestUnion::CreateRequest(cr)) => {
                                        let wid = if cr.watch_id != 0 { cr.watch_id } else {
                                            let id = next_watch_id;
                                            next_watch_id += 1;
                                            id
                                        };
                                        // Subscribe first, then send history, so no event is missed.
                                        let (history, cur_rev, compact_rev) = {
                                            let store = store_arc.lock().await;
                                            // etcd semantics: start_revision is INCLUSIVE
                                            // (deliver events with rev >= start_revision);
                                            // events_since is exclusive, so pass start-1.
                                            // start_revision == 0 means "from now".
                                            let hist = if cr.start_revision > 0 {
                                                store.events_since(cr.start_revision - 1)
                                            } else {
                                                Vec::new()
                                            };
                                            (hist, store.revision, store.compact_revision)
                                        };

                                        // Reject if start_revision was before compacted.
                                        if cr.start_revision > 0 && cr.start_revision <= compact_rev {
                                            let _ = tx.send(Ok(WatchResponse {
                                                watch_id:        wid,
                                                canceled:        true,
                                                compact_revision: compact_rev,
                                                cancel_reason:   "etcdserver: mvcc: required revision has been compacted".into(),
                                                ..Default::default()
                                            })).await;
                                            continue;
                                        }

                                        let filter = cr.filters.iter().fold(0u32, |acc, &f| {
                                            acc | (1 << (f as u32))
                                        });

                                        // Send created ack.
                                        let _ = tx.send(Ok(WatchResponse {
                                            header:   Some(ResponseHeader {
                                                cluster_id: crate::store::CLUSTER_ID,
                                                member_id:  crate::store::MEMBER_ID,
                                                revision:   cur_rev,
                                                raft_term:  1,
                                            }),
                                            watch_id: wid,
                                            created:  true,
                                            ..Default::default()
                                        })).await;

                                        // Replay history filtered by this handle's range/filter.
                                        let handle = WatchHandle {
                                            id:               wid,
                                            key:              cr.key.clone(),
                                            range_end:        cr.range_end.clone(),
                                            prev_kv:          cr.prev_kv,
                                            filter,
                                            // History replay went up to cur_rev; broadcast
                                            // events with rev ≤ cur_rev are duplicates.
                                            delivered_through: cur_rev,
                                        };

                                        for (rev, evs) in &history {
                                            let matched: Vec<Event> = evs.iter()
                                                .filter(|e| handle.matches(e.ev_type, &e.kv))
                                                .map(|e| {
                                                    let mut ev = kv_to_event(e);
                                                    if !handle.prev_kv { ev.prev_kv = None; }
                                                    ev
                                                })
                                                .collect();
                                            if !matched.is_empty() {
                                                let _ = tx.send(Ok(WatchResponse {
                                                    header: Some(ResponseHeader {
                                                        cluster_id: crate::store::CLUSTER_ID,
                                                        member_id:  crate::store::MEMBER_ID,
                                                        revision:   *rev,
                                                        raft_term:  1,
                                                    }),
                                                    watch_id: wid,
                                                    events:   matched,
                                                    ..Default::default()
                                                })).await;
                                            }
                                        }

                                        handles.push(handle);
                                    }
                                    Some(watch_request::RequestUnion::CancelRequest(cr)) => {
                                        handles.retain(|h| h.id != cr.watch_id);
                                        let _ = tx.send(Ok(WatchResponse {
                                            watch_id: cr.watch_id,
                                            canceled: true,
                                            ..Default::default()
                                        })).await;
                                    }
                                    Some(watch_request::RequestUnion::ProgressRequest(_)) => {
                                        let rev = store_arc.lock().await.revision;
                                        let _ = tx.send(Ok(WatchResponse {
                                            header: Some(ResponseHeader {
                                                cluster_id: crate::store::CLUSTER_ID,
                                                member_id:  crate::store::MEMBER_ID,
                                                revision:   rev,
                                                raft_term:  1,
                                            }),
                                            ..Default::default()
                                        })).await;
                                    }
                                    None => {}
                                }
                            }
                            _ => break, // client disconnected
                        }
                    }

                    // Broadcast from store
                    batch = bcast.recv() => {
                        match batch {
                            Ok(b) => {
                                if handles.is_empty() { continue; }
                                // Fan out to all active handles, skipping revisions
                                // already covered by history replay.
                                for handle in handles.iter_mut() {
                                    if b.revision <= handle.delivered_through { continue; }
                                    let matched: Vec<Event> = b.events.iter()
                                        .filter(|e| handle.matches(e.ev_type, &e.kv))
                                        .map(|e| {
                                            let mut ev = kv_to_event(e);
                                            if !handle.prev_kv { ev.prev_kv = None; }
                                            ev
                                        })
                                        .collect();
                                    handle.delivered_through = b.revision;
                                    if !matched.is_empty() {
                                        let _ = tx.send(Ok(WatchResponse {
                                            header: Some(ResponseHeader {
                                                cluster_id: crate::store::CLUSTER_ID,
                                                member_id:  crate::store::MEMBER_ID,
                                                revision:   b.revision,
                                                raft_term:  1,
                                            }),
                                            watch_id: handle.id,
                                            events:   matched,
                                            ..Default::default()
                                        })).await;
                                    }
                                }
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                                // We fell behind — cancel all watches (apiserver will reconnect).
                                eprintln!("etcd-mem: watch broadcast lagged by {n}, cancelling watches");
                                for h in handles.drain(..) {
                                    let _ = tx.send(Ok(WatchResponse {
                                        watch_id:     h.id,
                                        canceled:     true,
                                        cancel_reason:"broadcast lag — reconnect".into(),
                                        ..Default::default()
                                    })).await;
                                }
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                        }
                    }
                }
            }
        });

        let out = tokio_stream::wrappers::ReceiverStream::new(rx);
        Ok(Response::new(Box::pin(out)))
    }
}

// ─────────────────────────────── Lease ─────────────────────────────────────

pub struct LeaseSvc(pub SharedStore);

type KeepAliveStream = Pin<Box<dyn Stream<Item = Result<LeaseKeepAliveResponse, Status>> + Send>>;

#[tonic::async_trait]
impl LeaseTrait for LeaseSvc {
    async fn lease_grant(
        &self,
        req: Request<LeaseGrantRequest>,
    ) -> Result<Response<LeaseGrantResponse>, Status> {
        let r = req.into_inner();
        let mut store = self.0.lock().await;
        let (hdr, id, ttl) = store.lease_grant(r.ttl, r.id);
        Ok(Response::new(LeaseGrantResponse {
            header: Some(hdr),
            id,
            ttl,
            error: String::new(),
        }))
    }

    async fn lease_revoke(
        &self,
        req: Request<LeaseRevokeRequest>,
    ) -> Result<Response<LeaseRevokeResponse>, Status> {
        let r = req.into_inner();
        let mut store = self.0.lock().await;
        let hdr = store.lease_revoke(r.id);
        Ok(Response::new(LeaseRevokeResponse { header: Some(hdr) }))
    }

    type LeaseKeepAliveStream = KeepAliveStream;

    async fn lease_keep_alive(
        &self,
        req: Request<Streaming<LeaseKeepAliveRequest>>,
    ) -> Result<Response<Self::LeaseKeepAliveStream>, Status> {
        let store_arc = self.0.clone();
        let mut inbound = req.into_inner();
        let (tx, rx) = tokio::sync::mpsc::channel(64);

        tokio::spawn(async move {
            while let Ok(Some(r)) = inbound.message().await {
                let mut store = store_arc.lock().await;
                if let Some((hdr, id, ttl)) = store.lease_keepalive(r.id) {
                    let _ = tx.send(Ok(LeaseKeepAliveResponse {
                        header: Some(hdr), id, ttl,
                    })).await;
                } else {
                    // Lease not found — send 0 TTL to signal expiry.
                    let hdr = store.header();
                    let _ = tx.send(Ok(LeaseKeepAliveResponse {
                        header: Some(hdr), id: r.id, ttl: 0,
                    })).await;
                }
            }
        });

        Ok(Response::new(Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx))))
    }

    async fn lease_time_to_live(
        &self,
        req: Request<LeaseTimeToLiveRequest>,
    ) -> Result<Response<LeaseTimeToLiveResponse>, Status> {
        let r = req.into_inner();
        let store = self.0.lock().await;
        match store.lease_ttl(r.id, r.keys) {
            Some((hdr, id, ttl, keys)) => Ok(Response::new(LeaseTimeToLiveResponse {
                header:      Some(hdr),
                id,
                ttl,
                granted_ttl: store.leases.get(&id).map(|l| l.granted_ttl).unwrap_or(ttl),
                keys,
            })),
            None => Err(Status::not_found(format!("lease {:#x} not found", r.id))),
        }
    }

    async fn lease_leases(
        &self,
        _req: Request<LeaseLeasesRequest>,
    ) -> Result<Response<LeaseLeasesResponse>, Status> {
        let store = self.0.lock().await;
        let leases = store.lease_list().into_iter()
            .map(|id| LeaseStatus { id })
            .collect();
        Ok(Response::new(LeaseLeasesResponse {
            header: Some(store.header()),
            leases,
        }))
    }
}

// ─────────────────────────── Cluster ───────────────────────────────────────

pub struct ClusterSvc(pub SharedStore);

#[tonic::async_trait]
impl ClusterTrait for ClusterSvc {
    async fn member_list(
        &self,
        _req: Request<MemberListRequest>,
    ) -> Result<Response<MemberListResponse>, Status> {
        let store = self.0.lock().await;
        Ok(Response::new(MemberListResponse {
            header:  Some(store.header()),
            members: vec![Member {
                id:          crate::store::MEMBER_ID,
                name:        "etcd-mem".into(),
                peer_ur_ls:  vec![],
                client_ur_ls: vec![],
                is_learner:  false,
            }],
        }))
    }
}

// ─────────────────────────── Maintenance ────────────────────────────────────

pub struct MaintenanceSvc(pub SharedStore);

#[tonic::async_trait]
impl MaintenanceTrait for MaintenanceSvc {
    async fn defragment(
        &self,
        _req: Request<DefragmentRequest>,
    ) -> Result<Response<DefragmentResponse>, Status> {
        let store = self.0.lock().await;
        Ok(Response::new(DefragmentResponse { header: Some(store.header()) }))
    }

    async fn status(
        &self,
        _req: Request<StatusRequest>,
    ) -> Result<Response<StatusResponse>, Status> {
        let store = self.0.lock().await;
        Ok(Response::new(StatusResponse {
            header:            Some(store.header()),
            version:           "etcd-mem/0.1.0".into(),
            db_size:           0,
            leader:            crate::store::MEMBER_ID,
            raft_index:        store.revision as u64,
            raft_term:         1,
            raft_applied_index:store.revision as u64,
            errors:            vec![],
            db_size_in_use:    0,
            is_learner:        false,
        }))
    }

    async fn hash(
        &self,
        _req: Request<HashRequest>,
    ) -> Result<Response<HashResponse>, Status> {
        let store = self.0.lock().await;
        Ok(Response::new(HashResponse {
            header: Some(store.header()),
            hash:   0,
        }))
    }

    async fn hash_kv(
        &self,
        _req: Request<HashKvRequest>,
    ) -> Result<Response<HashKvResponse>, Status> {
        let store = self.0.lock().await;
        Ok(Response::new(HashKvResponse {
            header:           Some(store.header()),
            hash:             0,
            compact_revision: store.compact_revision,
        }))
    }
}
