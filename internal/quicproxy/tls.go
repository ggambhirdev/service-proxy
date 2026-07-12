// Package quicproxy implements the phase 3a/3b client<->proxy protocols:
// raw QUIC with a length-prefixed frame protocol (3a) and HTTP/3 (3b). The
// proxy->upstream leg is unchanged HTTP, reused via internal/upstream.
package quicproxy

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"math/big"
	"time"
)

// GenerateSelfSignedTLSConfig returns an in-memory TLS config with a
// self-signed certificate, suitable for QUIC/HTTP3 in this benchmarking
// harness (no real PKI needed).
func GenerateSelfSignedTLSConfig(nextProtos []string) (*tls.Config, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}

	cert := tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  key,
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   nextProtos,
	}, nil
}
