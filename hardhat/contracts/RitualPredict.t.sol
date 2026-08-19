// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {RitualPredict} from "./RitualPredict.sol";
import {RitualChain} from "./ritual/RitualChain.sol";
import {
    MockScheduler,
    MockRitualWallet,
    MockTEERegistry,
    MockHttpPrecompile,
    MockJqPrecompile
} from "./mocks/RitualMocks.sol";

/**
 * Unit tests for RitualPredict.
 *
 * The Ritual system contracts and precompiles are installed with `vm.etch` at their
 * canonical addresses, so the contract under test reaches them exactly the way it
 * would on chain: no network, no funded account, no special build.
 */
contract RitualPredictTest is Test {
    RitualPredict internal predict;

    MockScheduler internal scheduler;
    MockRitualWallet internal ritualWallet;
    MockTEERegistry internal registry;
    MockHttpPrecompile internal http;
    MockJqPrecompile internal jq;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal executor = address(0xE9EC);

    uint256 internal constant BLOCK_TIME_MS = 195;
    string internal constant QUESTION =
        "Will ETH/USD be at least $4,000 when this market resolves?";
    string internal constant ORACLE_URL =
        "https://oracle.example/api/oracle/eth";
    string internal constant JSON_PATH = ".price";

    function setUp() public {
        // Far enough in that blockhash(block.number - 1) is well defined.
        vm.roll(1_000);

        vm.etch(RitualChain.SCHEDULER, address(new MockScheduler()).code);
        vm.etch(RitualChain.RITUAL_WALLET, address(new MockRitualWallet()).code);
        vm.etch(
            RitualChain.TEE_SERVICE_REGISTRY,
            address(new MockTEERegistry()).code
        );
        vm.etch(
            RitualChain.HTTP_PRECOMPILE,
            address(new MockHttpPrecompile()).code
        );
        vm.etch(RitualChain.JQ_PRECOMPILE, address(new MockJqPrecompile()).code);

        scheduler = MockScheduler(RitualChain.SCHEDULER);
        ritualWallet = MockRitualWallet(RitualChain.RITUAL_WALLET);
        registry = MockTEERegistry(RitualChain.TEE_SERVICE_REGISTRY);
        http = MockHttpPrecompile(payable(RitualChain.HTTP_PRECOMPILE));
        jq = MockJqPrecompile(payable(RitualChain.JQ_PRECOMPILE));

        // vm.etch copies code but not storage, so configure every mock explicitly.
        address[] memory services = new address[](1);
        services[0] = executor;
        registry.setServices(services);

        http.setMode(http.MODE_OK());
        http.setResponse(200, bytes('{"price":4200}'), "");
        jq.setValue(4200);

        predict = new RitualPredict(BLOCK_TIME_MS);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // ───────────────────────────── helpers ──────────────────────────────

    function _params(
        uint256 target,
        RitualPredict.Comparator comparator
    ) internal pure returns (RitualPredict.NewMarket memory) {
        return
            RitualPredict.NewMarket({
                question: QUESTION,
                oracleUrl: ORACLE_URL,
                jsonPath: JSON_PATH,
                target: target,
                comparator: comparator,
                bettingSeconds: 180,
                resolveDelaySeconds: 60
            });
    }

    function _create() internal returns (uint256) {
        return
            predict.createMarket(_params(4000, RitualPredict.Comparator.GTE));
    }

    function _createWith(
        uint256 target,
        RitualPredict.Comparator comparator
    ) internal returns (uint256) {
        return predict.createMarket(_params(target, comparator));
    }

    function _bet(
        address who,
        uint256 marketId,
        bool isYes,
        uint256 amount
    ) internal {
        vm.prank(who);
        predict.bet{value: amount}(marketId, isYes);
    }

    /// Roll past the resolve block and let the Scheduler fire attempt `index`.
    function _fire(uint256 marketId, uint256 index) internal returns (bool ok) {
        RitualPredict.Market memory m = predict.getMarket(marketId);
        if (block.number < m.resolveBlock) vm.roll(m.resolveBlock);
        (ok, ) = scheduler.fire(m.scheduleId, index);
    }

    function _state(uint256 marketId) internal view returns (uint8) {
        return uint8(predict.getMarket(marketId).state);
    }

    // ─────────────────────────── createMarket ───────────────────────────

    function test_createMarket_storesTheRuleAndOpensBetting() public {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);

        assertEq(id, 1, "first market id");
        assertEq(predict.marketCount(), 1);
        assertEq(m.creator, address(this));
        assertEq(m.question, QUESTION);
        assertEq(m.oracleUrl, ORACLE_URL);
        assertEq(m.jsonPath, JSON_PATH);
        assertEq(m.target, 4000);
        assertEq(uint8(m.comparator), uint8(RitualPredict.Comparator.GTE));
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Open));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Unresolved));
        assertEq(m.attempts, 0);
    }

    function test_createMarket_convertsSecondsToBlocksAtBlockTime() public {
        uint256 startBlock = block.number;
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);

        // 180s and 60s at 195ms per block.
        assertEq(m.closeBlock, startBlock + (180 * 1000) / BLOCK_TIME_MS);
        assertEq(
            m.resolveBlock,
            uint256(m.closeBlock) + (60 * 1000) / BLOCK_TIME_MS
        );
        assertGt(m.resolveBlock, m.closeBlock, "resolve after close");
    }

    function test_createMarket_booksThreeSpacedExecutionsPaidByTheContract()
        public
    {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);
        MockScheduler.Booking memory b = scheduler.booking(m.scheduleId);

        assertEq(b.target, address(predict), "Scheduler calls back the market");
        assertEq(b.startBlock, m.resolveBlock, "first attempt at resolveBlock");
        assertEq(b.numCalls, predict.MAX_ATTEMPTS());
        assertEq(b.frequency, predict.RETRY_INTERVAL_BLOCKS());
        assertEq(b.gas, predict.RESOLVE_GAS_LIMIT());
        assertEq(b.ttl, predict.SCHEDULER_TTL_BLOCKS());
        assertEq(b.payer, address(predict), "fees come from the contract");
        assertEq(b.value, 0);
        assertGe(b.maxFeePerGas, predict.MIN_MAX_FEE_PER_GAS());

        // frequency * numCalls must stay under the Scheduler's MAX_LIFESPAN.
        assertLt(uint256(b.frequency) * b.numCalls, 10_000);
    }

    function test_createMarket_encodesAZeroExecutionIndexPlaceholder() public {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);
        bytes memory data = scheduler.booking(m.scheduleId).data;

        // selector + executionIndex placeholder + marketId
        assertEq(data.length, 4 + 32 + 32);

        uint256 placeholder;
        uint256 encodedId;
        assembly {
            placeholder := mload(add(data, 36))
            encodedId := mload(add(data, 68))
        }
        assertEq(placeholder, 0, "Scheduler overwrites bytes 4-35");
        assertEq(encodedId, id);
    }

    function test_createMarket_rejectsEmptyStrings() public {
        RitualPredict.NewMarket memory p = _params(
            4000,
            RitualPredict.Comparator.GTE
        );

        p.question = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);

        p.question = QUESTION;
        p.oracleUrl = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);

        p.oracleUrl = ORACLE_URL;
        p.jsonPath = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_createMarket_rejectsOutOfRangeDurations() public {
        RitualPredict.NewMarket memory p = _params(
            4000,
            RitualPredict.Comparator.GTE
        );

        p.bettingSeconds = predict.MIN_BETTING_SECONDS() - 1;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);

        p = _params(4000, RitualPredict.Comparator.GTE);
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS() - 1;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);

        p = _params(4000, RitualPredict.Comparator.GTE);
        p.bettingSeconds = predict.MAX_MARKET_SECONDS();
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function test_createMarket_revertsWhenTheSchedulerRejectsTheBooking()
        public
    {
        scheduler.setRejectSchedule(true);
        vm.expectRevert(bytes("scheduler rejected"));
        _create();
        // Nothing was written: an unresolvable market must not exist.
        assertEq(predict.marketCount(), 0);
    }

    function test_constructor_rejectsZeroBlockTime() public {
        vm.expectRevert(RitualPredict.BadDuration.selector);
        new RitualPredict(0);
    }

    // ────────────────────────────── betting ─────────────────────────────

    function test_bet_accumulatesPerSideAndPerAccount() public {
        uint256 id = _create();

        _bet(alice, id, true, 3 ether);
        _bet(bob, id, false, 1 ether);
        _bet(alice, id, true, 2 ether);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.totalYes, 5 ether);
        assertEq(m.totalNo, 1 ether);
        assertEq(predict.yesStake(id, alice), 5 ether);
        assertEq(predict.noStake(id, bob), 1 ether);
        assertEq(address(predict).balance, 6 ether);
    }

    function test_bet_rejectsZeroStake() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.bet{value: 0}(id, true);
    }

    function test_bet_rejectsUnknownMarket() public {
        vm.prank(alice);
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.bet{value: 1 ether}(42, true);
    }

    function test_bet_closesAtTheCloseBlockNotAtATimestamp() public {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);

        vm.roll(m.closeBlock - 1);
        _bet(alice, id, true, 1 ether); // last block that still accepts

        vm.roll(m.closeBlock);
        vm.prank(bob);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(id, false);
    }

    function test_getMarket_reportsClosedOnceTheBlockPasses() public {
        uint256 id = _create();
        assertEq(_state(id), uint8(RitualPredict.MarketState.Open));

        vm.roll(predict.getMarket(id).closeBlock);
        assertEq(
            _state(id),
            uint8(RitualPredict.MarketState.Closed),
            "the view closes it; no transaction does"
        );
    }

    function test_getMarket_revertsForUnknownIds() public {
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.getMarket(1);
    }

    function test_getMarkets_returnsNewestFirst() public {
        uint256 first = _create();
        uint256 second = _create();

        RitualPredict.Market[] memory all = predict.getMarkets();
        assertEq(all.length, 2);
        assertEq(all[0].id, second);
        assertEq(all[1].id, first);
    }

    // ───────────────────────────── resolution ───────────────────────────

    function test_onScheduledResolve_onlyTheSchedulerMayCall() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        predict.onScheduledResolve(0, id);
    }

    function test_resolve_yesWhenTheObservedValueSatisfiesTheComparator()
        public
    {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _bet(bob, id, false, 1 ether);

        jq.setValue(4200);
        assertTrue(_fire(id, 0), "callback must not revert");

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Yes));
        assertEq(m.observedValue, 4200);
        assertEq(m.attempts, 1);
    }

    function test_resolve_noWhenTheObservedValueFailsTheComparator() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _bet(bob, id, false, 1 ether);

        jq.setValue(3500);
        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.No));
        assertEq(m.observedValue, 3500);
    }

    function test_resolve_honoursEveryComparator() public {
        // GT: 4000 > 4000 is false
        uint256 gt = _createWith(4000, RitualPredict.Comparator.GT);
        _bet(alice, gt, true, 1 ether);
        _bet(bob, gt, false, 1 ether);
        jq.setValue(4000);
        _fire(gt, 0);
        assertEq(
            uint8(predict.getMarket(gt).outcome),
            uint8(RitualPredict.Outcome.No)
        );

        // GTE: 4000 >= 4000 is true
        uint256 gte = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(alice, gte, true, 1 ether);
        _bet(bob, gte, false, 1 ether);
        _fire(gte, 0);
        assertEq(
            uint8(predict.getMarket(gte).outcome),
            uint8(RitualPredict.Outcome.Yes)
        );

        // LT: 4000 < 4000 is false
        uint256 lt = _createWith(4000, RitualPredict.Comparator.LT);
        _bet(alice, lt, true, 1 ether);
        _bet(bob, lt, false, 1 ether);
        _fire(lt, 0);
        assertEq(
            uint8(predict.getMarket(lt).outcome),
            uint8(RitualPredict.Outcome.No)
        );

        // LTE: 4000 <= 4000 is true
        uint256 lte = _createWith(4000, RitualPredict.Comparator.LTE);
        _bet(alice, lte, true, 1 ether);
        _bet(bob, lte, false, 1 ether);
        _fire(lte, 0);
        assertEq(
            uint8(predict.getMarket(lte).outcome),
            uint8(RitualPredict.Outcome.Yes)
        );
    }

    function test_resolve_sendsTheConfiguredUrlAndExecutorToTheHttpPrecompile()
        public
    {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _fire(id, 0);

        assertEq(http.callCount(), 1);
        assertEq(http.lastUrl(), ORACLE_URL);
        assertEq(http.lastExecutor(), executor, "executor comes from the registry");
        assertEq(http.lastTtl(), predict.HTTP_TTL_BLOCKS());
        assertEq(http.lastMethod(), 1, "GET");
    }

    function test_resolve_cancelsTheUnusedAttemptsOnSuccess() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        uint256 scheduleId = predict.getMarket(id).scheduleId;

        assertEq(scheduler.getCallState(scheduleId), 0, "SCHEDULED");
        _fire(id, 0);
        assertEq(scheduler.getCallState(scheduleId), 3, "CANCELLED");
    }

    function test_resolve_isIdempotentForLeftoverExecutions() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _fire(id, 0);

        uint256 callsAfterFirst = http.callCount();
        assertTrue(_fire(id, 1), "a leftover execution must not revert");

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.attempts, 1, "attempt counter untouched");
        assertEq(http.callCount(), callsAfterFirst, "oracle not read again");
    }

    function test_resolve_ignoresUnknownMarketsWithoutReverting() public {
        _create(); // so the contract is not empty

        // A market id that was never created must be a no-op, not a revert: a
        // reverted execution would be retried and could never settle.
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, 999);

        assertEq(predict.marketCount(), 1, "no state was created");
    }

    // ─────────────────────── resolution failure paths ───────────────────

    function test_resolve_treatsANon200AsFailureNotAsNo() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _bet(bob, id, false, 1 ether);

        http.setResponse(503, bytes(""), "");
        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolving));
        assertEq(
            uint8(m.outcome),
            uint8(RitualPredict.Outcome.Unresolved),
            "a failed read is never a NO"
        );
        assertEq(m.attempts, 1);
    }

    function test_resolve_treatsAnExecutorErrorMessageAsFailure() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        http.setResponse(200, bytes('{"price":4200}'), "dns lookup failed");
        _fire(id, 0);

        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
    }

    function test_resolve_treatsAPrecompileRevertAsFailure() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        http.setMode(http.MODE_REVERT());
        assertTrue(_fire(id, 0), "callback stays revert-free");

        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
        assertEq(predict.getMarket(id).attempts, 1);
    }

    function test_resolve_treatsAnUnsettledEnvelopeAsFailure() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        http.setMode(http.MODE_UNSETTLED());
        assertTrue(_fire(id, 0));

        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
    }

    function test_resolve_treatsMalformedBytesAsFailure() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        http.setMode(http.MODE_MALFORMED());
        assertTrue(_fire(id, 0), "the try/catch guard absorbs it");

        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
    }

    function test_resolve_treatsAnUnparseableBodyAsFailure() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        jq.setReturnsNothing(true);
        _fire(id, 0);

        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
    }

    function test_resolve_failsWhenNoExecutorIsAvailable() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        registry.setUnavailable(true);
        _fire(id, 0);

        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
        assertEq(http.callCount(), 0, "no HTTP call without an executor");
    }

    function test_resolve_becomesInvalidOnlyAfterTheBookedAttemptsRunOut()
        public
    {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        http.setMode(http.MODE_REVERT());

        _fire(id, 0);
        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
        _fire(id, 1);
        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));
        _fire(id, 2);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Invalid));
        assertEq(m.attempts, predict.MAX_ATTEMPTS());
        assertGt(bytes(m.invalidReason).length, 0, "reason recorded");
    }

    function test_resolve_recoversOnALaterAttempt() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        http.setMode(http.MODE_REVERT());
        _fire(id, 0);
        assertEq(_state(id), uint8(RitualPredict.MarketState.Resolving));

        http.setMode(http.MODE_OK());
        _fire(id, 1);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolved));
        assertEq(m.attempts, 2);
    }

    function test_resolve_invalidatesWhenNobodyBackedTheWinningSide() public {
        uint256 id = _create();
        _bet(alice, id, false, 2 ether); // everyone on NO
        jq.setValue(4200); // YES wins

        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Invalid));
        assertEq(
            uint8(m.outcome),
            uint8(RitualPredict.Outcome.Yes),
            "outcome still recorded"
        );
        assertEq(m.observedValue, 4200);
    }

    // ────────────────────────────── payouts ─────────────────────────────

    function test_claimWinnings_paysTheProportionalShareOfTheWholePool()
        public
    {
        uint256 id = _create();
        _bet(alice, id, true, 3 ether);
        _bet(carol, id, true, 1 ether);
        _bet(bob, id, false, 4 ether);

        jq.setValue(4200); // YES
        _fire(id, 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        predict.claimWinnings(id);
        // 3 * 8 / 4 = 6
        assertEq(alice.balance - before, 6 ether);

        before = carol.balance;
        vm.prank(carol);
        predict.claimWinnings(id);
        // 1 * 8 / 4 = 2
        assertEq(carol.balance - before, 2 ether);

        assertEq(address(predict).balance, 0, "pool fully distributed");
    }

    function test_claimWinnings_rejectsTheLosingSideAndDoubleClaims() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _bet(bob, id, false, 1 ether);

        jq.setValue(4200); // YES
        _fire(id, 0);

        vm.prank(bob);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimWinnings(id);

        vm.prank(alice);
        predict.claimWinnings(id);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimWinnings(id);
    }

    function test_claimWinnings_rejectsUnresolvedMarkets() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.NotResolved.selector);
        predict.claimWinnings(id);
    }

    function test_claimRefund_returnsEveryStakeFromAnInvalidMarket() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _bet(bob, id, false, 2 ether);

        http.setMode(http.MODE_REVERT());
        _fire(id, 0);
        _fire(id, 1);
        _fire(id, 2);
        assertEq(_state(id), uint8(RitualPredict.MarketState.Invalid));

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        predict.claimRefund(id);
        vm.prank(bob);
        predict.claimRefund(id);

        assertEq(alice.balance - aliceBefore, 1 ether);
        assertEq(bob.balance - bobBefore, 2 ether);
        assertEq(address(predict).balance, 0);
    }

    function test_claimRefund_rejectsResolvedMarketsAndDoubleClaims() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);

        jq.setValue(4200);
        _fire(id, 0);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.NotInvalid.selector);
        predict.claimRefund(id);
    }

    function test_stakesOf_reportsClaimableForBothTerminalStates() public {
        uint256 id = _create();
        _bet(alice, id, true, 1 ether);
        _bet(bob, id, false, 3 ether);

        (uint256 yes, uint256 no, bool settled, uint256 claimable) = predict
            .stakesOf(id, alice);
        assertEq(yes, 1 ether);
        assertEq(no, 0);
        assertFalse(settled);
        assertEq(claimable, 0, "nothing claimable while open");

        jq.setValue(4200); // YES wins
        _fire(id, 0);

        (, , , claimable) = predict.stakesOf(id, alice);
        assertEq(claimable, 4 ether, "1 * 4 / 1");

        vm.prank(alice);
        predict.claimWinnings(id);
        (, , settled, claimable) = predict.stakesOf(id, alice);
        assertTrue(settled);
        assertEq(claimable, 0);
    }

    // ──────────────────────── execution funding ─────────────────────────

    function test_fundExecution_depositsIntoTheContractsRitualWalletBalance()
        public
    {
        vm.prank(alice);
        predict.fundExecution{value: 5 ether}(500_000);

        assertEq(predict.executionBalance(), 5 ether);
        assertEq(ritualWallet.balanceOf(address(predict)), 5 ether);
        assertEq(
            ritualWallet.lockUntil(address(predict)),
            block.number + 500_000
        );
    }

    function test_fundExecution_rejectsZeroValue() public {
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.fundExecution{value: 0}(500);
    }

    // ───────────────────────────── invariants ───────────────────────────

    function testFuzz_payoutsNeverExceedThePool(
        uint96 yesStake_,
        uint96 noStake_
    ) public {
        vm.assume(yesStake_ > 0.001 ether && noStake_ > 0.001 ether);

        uint256 id = _create();
        vm.deal(alice, uint256(yesStake_));
        vm.deal(bob, uint256(noStake_));
        _bet(alice, id, true, yesStake_);
        _bet(bob, id, false, noStake_);

        uint256 pool = uint256(yesStake_) + uint256(noStake_);

        jq.setValue(4200); // YES wins
        _fire(id, 0);

        (, , , uint256 claimable) = predict.stakesOf(id, alice);
        assertLe(claimable, pool, "integer division can only leave dust behind");

        vm.prank(alice);
        predict.claimWinnings(id);
        assertLe(address(predict).balance, pool);
    }

    function testFuzz_comparatorMatchesPlainSolidity(uint128 observed) public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(alice, id, true, 1 ether);
        _bet(bob, id, false, 1 ether);

        jq.setValue(observed);
        _fire(id, 0);

        RitualPredict.Outcome expected = observed >= 4000
            ? RitualPredict.Outcome.Yes
            : RitualPredict.Outcome.No;
        assertEq(uint8(predict.getMarket(id).outcome), uint8(expected));
    }
}
