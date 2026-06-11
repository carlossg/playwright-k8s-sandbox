Vendored proto-generated Go bindings for substrate's Control gRPC API.

Source: `github.com/agent-substrate/substrate/pkg/proto/ateapipb` (Apache 2.0).

We copy the generated files here rather than `go get` the substrate module because
substrate brings ~hundreds of MB of cloud-provider deps that this proxy doesn't
need. When the upstream substrate proto changes (new RPCs, new fields), re-copy
`ateapi.pb.go` and `ateapi_grpc.pb.go`.
