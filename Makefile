.PHONY: bench0 bench1a bench1b bench2a bench2b bench3a bench3b bench4 bench5

OUT_DIR := benchmark-findings/output/raw

PHASE0_N := 100 250 500 1000 2000
PHASE1_N := 100 250 500 1000 2000 3000 4000

# Phase 4 sweeps only the high offered loads (loss %/jitter is the variable of
# interest, not RPS) across a fixed set of stress cases. baseline = no netem.
PHASE4_N := 2000 4000
PHASE4_CASES := baseline loss1 loss5 jitter50

# oha built with `cargo install --features http3 oha`, installed under a
# distinct name so it doesn't shadow the plain oha used by the other targets.
OHA_HTTP3 ?= oha-http3

# Phase 0: TCP baseline (single client/proxy/upstream, HTTP/1.1)
bench0:
	mkdir -p $(OUT_DIR)
	docker compose -f deploy/phase0/docker-compose.yml up --build -d --wait
	for n in $(PHASE0_N); do \
		echo "=== Phase 0, N=$$n ==="; \
		oha -z 10s -q $$n -c 50 --latency-correction http://localhost:8080 > /dev/null; \
		oha -z 30s -q $$n -c 50 --latency-correction http://localhost:8080 > $(OUT_DIR)/phase0_N$$n.txt; \
	done
	docker compose -f deploy/phase0/docker-compose.yml down

# Phase 1a: goroutine-per-connection concurrency, HTTP/1.1
bench1a:
	mkdir -p $(OUT_DIR)
	docker compose -f deploy/phase1a/docker-compose.yml up --build -d --wait
	for n in $(PHASE1_N); do \
		echo "=== Phase 1a, N=$$n ==="; \
		oha -z 10s -q $$n -c 50 --latency-correction http://localhost:8080 > /dev/null; \
		oha -z 30s -q $$n -c 50 --latency-correction http://localhost:8080 > $(OUT_DIR)/phase1a_N$$n.txt; \
	done
	docker compose -f deploy/phase1a/docker-compose.yml down

# Phase 1b: HTTP/2 (h2c), /echo endpoint
bench1b:
	mkdir -p $(OUT_DIR)
	docker compose -f deploy/phase1b/docker-compose.yml up --build -d --wait
	for n in $(PHASE1_N); do \
		echo "=== Phase 1b, N=$$n ==="; \
		oha -z 10s -q $$n -c 1 -p 50 --latency-correction --http2 http://localhost:8080/echo > /dev/null; \
		oha -z 30s -q $$n -c 1 -p 50 --latency-correction --http2 http://localhost:8080/echo > $(OUT_DIR)/phase1b_N$$n.txt; \
	done
	docker compose -f deploy/phase1b/docker-compose.yml down

# Phase 2a: pooled upstream connections + worker pool, HTTP/1.1
bench2a:
	mkdir -p $(OUT_DIR)
	docker compose -f deploy/phase2a/docker-compose.yml up --build -d --wait
	for n in $(PHASE1_N); do \
		echo "=== Phase 2a, N=$$n ==="; \
		oha -z 10s -q $$n -c 50 --latency-correction http://localhost:8080 > /dev/null; \
		oha -z 30s -q $$n -c 50 --latency-correction http://localhost:8080 > $(OUT_DIR)/phase2a_N$$n.txt; \
	done
	docker compose -f deploy/phase2a/docker-compose.yml down

# Phase 2b: gRPC over HTTP/2, pooled upstream connections
#
# Uses the same discarded-warmup / measured-run split as the oha-based
# targets rather than ghz's --skipFirst: ghz's own Requests/sec divides the
# post-skip count by the *entire* -z duration (including however long
# --skipFirst took to clear), which silently deflates the reported
# throughput -- worse the further the achieved rate lags the offered rate.
# Two separate runs, neither using --skipFirst, avoids this entirely.
bench2b:
	mkdir -p $(OUT_DIR)
	docker compose -f deploy/phase2b/docker-compose.yml up --build -d --wait
	for n in $(PHASE1_N); do \
		echo "=== Phase 2b, N=$$n ==="; \
		ghz -z 10s -r $$n -c 50 --connections=1 --async --insecure \
			--data '{"payload": ""}' \
			--proto internal/grpcproxy/proto/echo.proto \
			--call echo.EchoService.Echo \
			localhost:8080 > /dev/null; \
		ghz -z 30s -r $$n -c 50 --connections=1 --async --insecure \
			--data '{"payload": ""}' \
			--proto internal/grpcproxy/proto/echo.proto \
			--call echo.EchoService.Echo \
			localhost:8080 > $(OUT_DIR)/phase2b_N$$n.txt; \
	done
	docker compose -f deploy/phase2b/docker-compose.yml down

# Phase 3a: raw QUIC, in-house open-loop load generator (cmd/quic-bench-client)
bench3a:
	mkdir -p $(OUT_DIR)
	docker compose -f deploy/phase3a/docker-compose.yml up --build -d --wait
	for n in $(PHASE1_N); do \
		echo "=== Phase 3a, N=$$n ==="; \
		go run ./cmd/quic-bench-client -addr localhost:8443 -rate $$n -duration 10s > /dev/null; \
		go run ./cmd/quic-bench-client -addr localhost:8443 -rate $$n -duration 30s > $(OUT_DIR)/phase3a_N$$n.txt; \
	done
	docker compose -f deploy/phase3a/docker-compose.yml down

# Phase 3b: HTTP/3 over QUIC, oha experimental http3 build (see OHA_HTTP3 above)
bench3b:
	mkdir -p $(OUT_DIR)
	docker compose -f deploy/phase3b/docker-compose.yml up --build -d --wait
	for n in $(PHASE1_N); do \
		echo "=== Phase 3b, N=$$n ==="; \
		$(OHA_HTTP3) -z 10s -q $$n -c 50 --http-version 3 --insecure --latency-correction https://localhost:8443/echo > /dev/null; \
		$(OHA_HTTP3) -z 30s -q $$n -c 50 --http-version 3 --insecure --latency-correction https://localhost:8443/echo > $(OUT_DIR)/phase3b_N$$n.txt; \
	done
	docker compose -f deploy/phase3b/docker-compose.yml down

# Phase 4: stress conditions. Re-runs the pooled phases (2a pooled HTTP/1.1,
# 2b gRPC, 3b HTTP/3) unchanged, under tc netem packet loss / jitter injected
# on the proxy container's eth0 via scripts/netem.sh (helper container, no
# image/compose changes). Records tail latency + success/error rate per stress
# case at the high offered loads only. Each phase keeps its own load tool and
# endpoint; all hit /echo so the work is equivalent across protocols. On Mac,
# run scripts/fix-docker-udp-buffers.sh once before the 3b leg (as with bench3b).
bench4:
	mkdir -p $(OUT_DIR)
	for phase in 2a 2b 3b; do \
		compose=deploy/phase$$phase/docker-compose.yml; \
		echo "=== Phase 4, proxy phase=$$phase ==="; \
		docker compose -f $$compose up --build -d --wait; \
		for case in $(PHASE4_CASES); do \
			scripts/netem.sh $$compose del >/dev/null 2>&1 || true; \
			case "$$case" in \
				baseline) : ;; \
				loss1)    scripts/netem.sh $$compose add loss 1% ;; \
				loss5)    scripts/netem.sh $$compose add loss 5% ;; \
				jitter50) scripts/netem.sh $$compose add delay 50ms 10ms distribution normal ;; \
			esac; \
			for n in $(PHASE4_N); do \
				out=$(OUT_DIR)/phase4_$${phase}_$${case}_N$$n.txt; \
				echo "--- phase=$$phase case=$$case N=$$n ---"; \
				case "$$phase" in \
					2a) oha -z 10s -q $$n -c 50 --latency-correction http://localhost:8080/echo > /dev/null; \
					    oha -z 30s -q $$n -c 50 --latency-correction http://localhost:8080/echo > $$out ;; \
					2b) ghz -z 10s -r $$n -c 50 --connections=1 --async --insecure --data '{"payload": ""}' --proto internal/grpcproxy/proto/echo.proto --call echo.EchoService.Echo localhost:8080 > /dev/null; \
					    ghz -z 30s -r $$n -c 50 --connections=1 --async --insecure --data '{"payload": ""}' --proto internal/grpcproxy/proto/echo.proto --call echo.EchoService.Echo localhost:8080 > $$out ;; \
					3b) $(OHA_HTTP3) -z 10s -q $$n -c 50 --http-version 3 --insecure --latency-correction https://localhost:8443/echo > /dev/null; \
					    $(OHA_HTTP3) -z 30s -q $$n -c 50 --http-version 3 --insecure --latency-correction https://localhost:8443/echo > $$out ;; \
				esac; \
			done; \
		done; \
		scripts/netem.sh $$compose del >/dev/null 2>&1 || true; \
		docker compose -f $$compose down; \
	done

# Phase 5: load balancing (pooled HTTP/1.1, 8 upstreams; f/g/h deliberately
# slow). Sweeps the three strategies -- 5a round-robin / 5b least-conn / 5c
# p2c -- over the full N sweep, one file switched via LB_STRATEGY. Hits /echo
# (not /) so the slow upstreams' artificial delay actually fires. Alongside
# oha latency/throughput it captures per-upstream request distribution from
# the proxy's /stats endpoint (:9090), resetting after the warmup so the
# recorded distribution reflects only the measured run. The distribution is
# the point: least-conn/p2c should route around f/g/h that round-robin hits
# evenly.
bench5:
	mkdir -p $(OUT_DIR)
	for s in round-robin least-conn p2c; do \
		echo "=== Phase 5, strategy=$$s ==="; \
		LB_STRATEGY=$$s docker compose -f deploy/phase5/docker-compose.yml up --build -d --wait; \
		for n in $(PHASE1_N); do \
			echo "--- strategy=$$s N=$$n ---"; \
			oha -z 10s -q $$n -c 50 --latency-correction http://localhost:8080/echo > /dev/null; \
			curl -s 'http://localhost:9090/stats?reset=1' > /dev/null; \
			oha -z 30s -q $$n -c 50 --latency-correction http://localhost:8080/echo > $(OUT_DIR)/phase5_$${s}_N$$n.txt; \
			curl -s http://localhost:9090/stats > $(OUT_DIR)/phase5_$${s}_N$$n.stats.json; \
		done; \
		docker compose -f deploy/phase5/docker-compose.yml down; \
	done
