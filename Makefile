# One-command local demo:  make demo   (then in other terminals: make keeper / make allocator / make ui)
RPC ?= http://127.0.0.1:8545
export PATH := $(HOME)/.foundry/bin:$(PATH)

.PHONY: build test cov anvil deploy seed demo keeper allocator crash status ui

build:
	forge build

test:
	forge test -vv

cov:
	forge coverage --ir-minimum --report summary

anvil:
	anvil --block-time 2

deploy:
	forge script script/Deploy.s.sol --rpc-url $(RPC) --broadcast
	cd keeper && npm install --silent && npm run -s abis

seed:
	cast rpc --rpc-url $(RPC) evm_increaseTime 86401 > /dev/null
	cast rpc --rpc-url $(RPC) evm_mine > /dev/null
	forge script script/Seed.s.sol --rpc-url $(RPC) --broadcast

demo: build deploy seed status

keeper:
	cd keeper && npm run liquidator

allocator:
	cd keeper && npm run allocator

crash:
	cd keeper && npm run crash -- $(or $(PCT),8)

status:
	cd keeper && npm run -s status

ui:
	cd dashboard && npm install --silent && npm run dev
