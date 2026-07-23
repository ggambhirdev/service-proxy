use clap::Parser;
use proto::echo_service_client::EchoServiceClient;
use proto::EchoRequest;

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "http://127.0.0.1:8080")]
    addr: String,
    #[arg(long, default_value = "hello")]
    payload: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let mut client = EchoServiceClient::connect(args.addr).await?;
    let resp = client
        .echo(EchoRequest {
            payload: args.payload.into_bytes(),
        })
        .await?
        .into_inner();
    println!(
        "payload={} upstream_id={}",
        String::from_utf8_lossy(&resp.payload),
        resp.upstream_id
    );
    Ok(())
}
