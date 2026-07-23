package upstream

import (
	"context"
	"net"
	"sync/atomic"
)

// Pool is a bounded set of reusable TCP connections to a single upstream
// address (phase 2: stop dialing per request). Connections are dialed
// lazily on demand, up to maxSize concurrently outstanding; eviction is
// error-driven — a connection that errors during use is closed and not
// returned to the pool, so the next Get dials fresh.
type Pool struct {
	addr        string
	conns       chan net.Conn
	maxSize     int
	outstanding atomic.Int32
}

// NewPool returns a Pool for addr that allows up to maxSize concurrently
// outstanding connections.
func NewPool(addr string, maxSize int) *Pool {
	return &Pool{
		addr:    addr,
		conns:   make(chan net.Conn, maxSize),
		maxSize: maxSize,
	}
}

// Get returns an idle pooled connection if one is available, dials a new
// one if the pool is under maxSize, or blocks until a connection is
// returned (or ctx is done) if the pool is at capacity.
func (p *Pool) Get(ctx context.Context) (net.Conn, error) {
	select {
	case conn := <-p.conns:
		return conn, nil
	default:
	}

	if p.outstanding.Add(1) <= int32(p.maxSize) {
		conn, err := Dial(p.addr)
		if err != nil {
			p.outstanding.Add(-1)
			return nil, err
		}
		return conn, nil
	}
	p.outstanding.Add(-1)

	select {
	case conn := <-p.conns:
		return conn, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Put returns conn to the pool if healthy is true, or closes it and frees
// its slot otherwise.
func (p *Pool) Put(conn net.Conn, healthy bool) {
	if !healthy {
		conn.Close()
		p.outstanding.Add(-1)
		return
	}

	select {
	case p.conns <- conn:
	default:
		// Pool full (shouldn't happen if accounting is correct) — drop it.
		conn.Close()
		p.outstanding.Add(-1)
	}
}

// Manager holds one Pool per upstream address.
type Manager struct {
	pools map[string]*Pool
}

// NewManager returns a Manager with one Pool per addr in addrs, each
// allowing up to sizePerUpstream outstanding connections.
func NewManager(addrs []string, sizePerUpstream int) *Manager {
	pools := make(map[string]*Pool, len(addrs))
	for _, addr := range addrs {
		pools[addr] = NewPool(addr, sizePerUpstream)
	}
	return &Manager{pools: pools}
}

// Pool returns the Pool for addr.
func (m *Manager) Pool(addr string) *Pool {
	return m.pools[addr]
}

// ForwardPooled forwards req using a connection from pool, returning the
// connection to the pool on success or discarding it on error so the next
// Get dials fresh.
func ForwardPooled(ctx context.Context, pool *Pool, req *Request) (*Response, error) {
	conn, err := pool.Get(ctx)
	if err != nil {
		return nil, err
	}

	resp, err := Forward(conn, req)
	if err != nil {
		pool.Put(conn, false)
		return nil, err
	}

	pool.Put(conn, true)
	return resp, nil
}

// Forwarder forwards a request to addr, abstracting over per-request
// dialing (phases 0/1a/1b) vs. pooled connections (phase 2+).
type Forwarder interface {
	Forward(addr string, req *Request) (*Response, error)
}

// DialForwarder forwards each request over a freshly dialed connection
// (phases 0/1a).
type DialForwarder struct{}

// Forward implements Forwarder.
func (DialForwarder) Forward(addr string, req *Request) (*Response, error) {
	return ForwardHTTP(addr, req)
}

// PoolForwarder forwards each request using Manager's pooled connections
// (phase 2).
type PoolForwarder struct {
	Manager *Manager
}

// Forward implements Forwarder.
func (f PoolForwarder) Forward(addr string, req *Request) (*Response, error) {
	return ForwardPooled(context.Background(), f.Manager.Pool(addr), req)
}
