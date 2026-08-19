/**
 * End-to-end walkthroughs of the workshop flow, driven from TypeScript the way a
 * frontend would drive it: create a market, take bets from two accounts, let the
 * Scheduler wake the contract, then settle up.
 *
 * The Ritual system contracts and precompiles are installed at their canonical
 * addresses with `hardhat_setCode`, so `RitualPredict` talks to exactly the
 * addresses it would use on chain. No network and no funded account are needed.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, parseEther, toHex, type Address } from "viem";

/** Canonical addresses — must match contracts/ritual/RitualChain.sol. */
const RITUAL = {
  scheduler: "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B",
  ritualWallet: "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948",
  teeRegistry: "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F",
  http: "0x0000000000000000000000000000000000000801",
  jq: "0x0000000000000000000000000000000000000803",
} as const satisfies Record<string, Address>;

const MARKET_STATE = ["Open", "Closed", "Resolving", "Resolved", "Invalid"] as const;
const OUTCOME = ["Unresolved", "YES", "NO"] as const;

const BLOCK_TIME_MS = 195n;
const EXECUTOR: Address = getAddress(
  "0x00000000000000000000000000000000000e9ec0",
);

const DEMO_MARKET = {
  question: "Will ETH/USD be at least $4,000 when this market resolves?",
  oracleUrl: "https://oracle.example/api/oracle/eth",
  jsonPath: ".price",
  target: 4000n,
  comparator: 1, // GTE
  bettingSeconds: 180n,
  resolveDelaySeconds: 60n,
} as const;

/**
 * Fresh chain, mocks etched at the canonical addresses, contract deployed.
 * Each test gets its own connection so state never leaks between them.
 */
async function setup() {
  const connection = await network.create();
  const { viem, networkHelpers, provider } = connection;

  const publicClient = await viem.getPublicClient();
  const [deployer, alice, bob] = await viem.getWalletClients();

  // Deploy each mock normally, then copy its runtime code to the canonical address.
  const placements = [
    ["MockScheduler", RITUAL.scheduler],
    ["MockRitualWallet", RITUAL.ritualWallet],
    ["MockTEERegistry", RITUAL.teeRegistry],
    ["MockHttpPrecompile", RITUAL.http],
    ["MockJqPrecompile", RITUAL.jq],
  ] as const;

  for (const [name, target] of placements) {
    const impl = await viem.deployContract(name);
    const code = await publicClient.getCode({ address: impl.address });
    assert.ok(code, `${name} has no runtime code`);
    await provider.request({ method: "hardhat_setCode", params: [target, code] });
  }

  const scheduler = await viem.getContractAt("MockScheduler", RITUAL.scheduler);
  const registry = await viem.getContractAt("MockTEERegistry", RITUAL.teeRegistry);
  const http = await viem.getContractAt("MockHttpPrecompile", RITUAL.http);
  const jq = await viem.getContractAt("MockJqPrecompile", RITUAL.jq);

  // hardhat_setCode copies code but not storage: configure every mock explicitly.
  await registry.write.setServices([[EXECUTOR]]);
  await http.write.setMode([0]); // MODE_OK
  await http.write.setResponse([200, toHex('{"price":4200}'), ""]);
  await jq.write.setValue([4200n]);

  const predict = await viem.deployContract("RitualPredict", [BLOCK_TIME_MS]);

  const asAlice = await viem.getContractAt("RitualPredict", predict.address, {
    client: { wallet: alice },
  });
  const asBob = await viem.getContractAt("RitualPredict", predict.address, {
    client: { wallet: bob },
  });

  return {
    connection,
    publicClient,
    networkHelpers,
    deployer,
    alice,
    bob,
    predict,
    asAlice,
    asBob,
    scheduler,
    registry,
    http,
    jq,
  };
}

/** Mine until the market's scheduled resolve block, then fire attempt `index`. */
async function fire(
  ctx: Awaited<ReturnType<typeof setup>>,
  marketId: bigint,
  index: bigint,
) {
  const market = await ctx.predict.read.getMarket([marketId]);
  const current = await ctx.publicClient.getBlockNumber();
  if (current < market.resolveBlock) {
    await ctx.networkHelpers.mine(Number(market.resolveBlock - current));
  }
  // An explicit gas limit is load-bearing. `fire` swallows a failed inner call the
  // way the real Scheduler does, so gas estimation happily returns a figure that is
  // too small to run the callback at all, and the callback would silently no-op.
  await ctx.scheduler.write.fire([market.scheduleId, index], {
    gas: 10_000_000n,
  });
}

describe("RitualPredict end to end", () => {
  it("settles itself from the oracle and pays the winning side", async () => {
    const ctx = await setup();
    const { predict, asAlice, asBob, publicClient, http } = ctx;

    await predict.write.createMarket([DEMO_MARKET]);
    const marketId = 1n;

    await asAlice.write.bet([marketId, true], { value: parseEther("3") });
    await asBob.write.bet([marketId, false], { value: parseEther("1") });

    let market = await predict.read.getMarket([marketId]);
    assert.equal(MARKET_STATE[market.state], "Open");
    assert.equal(market.totalYes, parseEther("3"));
    assert.equal(market.totalNo, parseEther("1"));

    // Nobody presses resolve: the Scheduler wakes the contract.
    await fire(ctx, marketId, 0n);

    market = await predict.read.getMarket([marketId]);
    assert.equal(MARKET_STATE[market.state], "Resolved");
    assert.equal(OUTCOME[market.outcome], "YES", "4200 >= 4000");
    assert.equal(market.observedValue, 4200n);
    assert.equal(market.attempts, 1);

    // The read went out over the HTTP precompile with the configured rule.
    assert.equal(await http.read.callCount(), 1n);
    assert.equal(await http.read.lastUrl(), DEMO_MARKET.oracleUrl);
    assert.equal(getAddress(await http.read.lastExecutor()), getAddress(EXECUTOR));

    // Pari-mutuel: the whole 4 RITUAL pool goes to the single YES backer.
    const [, , , claimable] = await predict.read.stakesOf([
      marketId,
      ctx.alice.account.address,
    ]);
    assert.equal(claimable, parseEther("4"));

    await asAlice.write.claimWinnings([marketId]);
    assert.equal(
      await publicClient.getBalance({ address: predict.address }),
      0n,
      "pool fully distributed",
    );

    await ctx.connection.close();
  });

  it("becomes refundable when the oracle never answers", async () => {
    const ctx = await setup();
    const { predict, asAlice, asBob, publicClient, http } = ctx;

    await predict.write.createMarket([DEMO_MARKET]);
    const marketId = 1n;

    await asAlice.write.bet([marketId, true], { value: parseEther("1") });
    await asBob.write.bet([marketId, false], { value: parseEther("2") });

    await http.write.setMode([1]); // MODE_REVERT — executor unreachable

    // A failed read is never a NO: the market only gives up once the three booked
    // attempts are gone.
    await fire(ctx, marketId, 0n);
    assert.equal(
      MARKET_STATE[(await predict.read.getMarket([marketId])).state],
      "Resolving",
    );

    await fire(ctx, marketId, 1n);
    await fire(ctx, marketId, 2n);

    const market = await predict.read.getMarket([marketId]);
    assert.equal(MARKET_STATE[market.state], "Invalid");
    assert.equal(OUTCOME[market.outcome], "Unresolved");
    assert.equal(market.attempts, 3);
    assert.ok(market.invalidReason.length > 0, "reason recorded");

    await asAlice.write.claimRefund([marketId]);
    await asBob.write.claimRefund([marketId]);
    assert.equal(
      await publicClient.getBalance({ address: predict.address }),
      0n,
      "every stake returned",
    );

    await ctx.connection.close();
  });
});
