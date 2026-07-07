fn main() {
    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .compile_protos(&["proto/rpc.proto"], &["proto"])
        .expect("failed to compile etcd proto");
}
