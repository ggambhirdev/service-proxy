//! Phase 2b gRPC EchoService → upstream HTTP forward.

use std::collections::HashMap;
use std::sync::Arc;

use bytes::Bytes;
use proto::echo_service_server::{EchoService, EchoServiceServer};
use proto::{EchoRequest, EchoResponse};
use tonic::{Request, Response, Status};

use crate::upstream::{ForwarderKind, Request as UpstreamRequest, Selector, SelectorKind};

pub struct GrpcProxy {
    selector: Arc<SelectorKind>,
    forwarder: ForwarderKind,
}

impl GrpcProxy {
    pub fn new(selector: Arc<SelectorKind>, forwarder: ForwarderKind) -> Self {
        Self {
            selector,
            forwarder,
        }
    }

    pub fn into_server(self) -> EchoServiceServer<Self> {
        EchoServiceServer::new(self)
    }
}

#[tonic::async_trait]
impl EchoService for GrpcProxy {
    async fn echo(&self, req: Request<EchoRequest>) -> Result<Response<EchoResponse>, Status> {
        let payload = req.into_inner().payload;
        let (addr, tok) = self.selector.next();
        let mut headers = HashMap::new();
        headers.insert(
            "Content-Type".into(),
            vec!["application/octet-stream".into()],
        );
        let result = self
            .forwarder
            .forward(
                &addr,
                &UpstreamRequest {
                    method: "POST".into(),
                    path: "/echo".into(),
                    host: addr.clone(),
                    headers,
                    body: Bytes::from(payload),
                },
            )
            .await;
        self.selector.release(tok);

        match result {
            Ok(resp) => {
                let upstream_id = resp
                    .headers
                    .get("X-Upstream-Id")
                    .or_else(|| resp.headers.get("X-Upstream-ID"))
                    .and_then(|v| v.first().cloned())
                    .unwrap_or_default();
                Ok(Response::new(EchoResponse {
                    payload: resp.body.to_vec(),
                    upstream_id,
                }))
            }
            Err(e) => Err(Status::unavailable(format!("forward to {addr}: {e}"))),
        }
    }
}
