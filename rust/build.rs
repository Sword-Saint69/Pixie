fn main() {
    // Wire schemas are copied verbatim from xob0t/gotohp @ 2a5c1b9 (.proto/).
    // prost keeps unknown fields on decode, matching the upstream Go code's
    // forward-compatible parse of the private Photos endpoints.
    let protos = [
        "proto/AddMediaToAlbum.proto",
        "proto/CommitToken.proto",
        "proto/CommitUpload.proto",
        "proto/CreateAlbum.proto",
        "proto/CreateAlbumResponse.proto",
        "proto/CreateMediaItems.proto",
        "proto/GetUploadToken.proto",
        "proto/HashCheck.proto",
        "proto/RemoteMatches.proto",
    ];

    prost_build::compile_protos(&protos, &["proto"]).expect("compile protobuf schemas");
    println!("cargo:rerun-if-changed=proto");
}
