//! 4-byte big-endian length-prefixed frames (phase 3a).

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Result<Vec<u8>, std::io::Error> {
    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).await?;
    Ok(buf)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(
    w: &mut W,
    payload: &[u8],
) -> Result<(), std::io::Error> {
    let len = (payload.len() as u32).to_be_bytes();
    w.write_all(&len).await?;
    w.write_all(payload).await?;
    w.flush().await?;
    Ok(())
}
