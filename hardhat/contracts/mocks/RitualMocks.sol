// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * Test-only stand-ins for the Ritual system contracts and precompiles.
 *
 * These are meant to be installed with `vm.etch` at the canonical addresses in
 * `RitualChain.sol`, so the contract under test reaches them through exactly the
 * same addresses it uses on chain. `vm.etch` copies runtime code but NOT storage,
 * so nothing here may rely on a constructor: every mock starts from zeroed storage
 * and must be configured explicitly by the test.
 */

// ─────────────────────────────── Scheduler ───────────────────────────────

/**
 * Records bookings instead of executing them, and exposes `fire()` so a test can
 * drive an execution by hand. `fire` reproduces the one detail that matters most:
 * the real Scheduler overwrites calldata bytes 4-35 with the execution index.
 */
contract MockScheduler {
    struct Booking {
        address target;
        bytes data;
        uint32 gas;
        uint32 startBlock;
        uint32 numCalls;
        uint32 frequency;
        uint32 ttl;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 value;
        address payer;
        bool cancelled;
    }

    uint256 internal _nextCallId;
    mapping(uint256 => Booking) internal _bookings;
    mapping(address => bool) public approved;

    /// Set by a test to make `schedule` revert, exercising the create path.
    bool public rejectSchedule;

    function setRejectSchedule(bool v) external {
        rejectSchedule = v;
    }

    function approveScheduler(address schedulerContract) external {
        approved[msg.sender] = schedulerContract != address(0);
    }

    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId) {
        require(!rejectSchedule, "scheduler rejected");
        // Fresh (etched) storage starts at 0, so pre-increment makes ids start at 1.
        callId = ++_nextCallId;
        _bookings[callId] = Booking({
            target: msg.sender,
            data: data,
            gas: gas,
            startBlock: startBlock,
            numCalls: numCalls,
            frequency: frequency,
            ttl: ttl,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            value: value,
            payer: payer,
            cancelled: false
        });
    }

    function cancel(uint256 callId) external {
        _bookings[callId].cancelled = true;
    }

    /// 0 = SCHEDULED, 3 = CANCELLED — the two states this mock distinguishes.
    function getCallState(uint256 callId) external view returns (uint8) {
        return _bookings[callId].cancelled ? 3 : 0;
    }

    function booking(uint256 callId) external view returns (Booking memory) {
        return _bookings[callId];
    }

    function callCount() external view returns (uint256) {
        return _nextCallId;
    }

    /**
     * Drive execution `index` of `callId`, the way the Scheduler would.
     * Returns the raw success flag so a test can assert the callback never reverts.
     */
    function fire(
        uint256 callId,
        uint256 index
    ) external returns (bool ok, bytes memory ret) {
        Booking storage b = _bookings[callId];
        bytes memory data = b.data;
        // Content starts at data+32; bytes 4-35 of the calldata therefore live at
        // data+36. This is the executionIndex slot.
        assembly {
            mstore(add(data, 36), index)
        }
        (ok, ret) = b.target.call{gas: 3_000_000}(data);
    }
}

// ────────────────────────────── RitualWallet ─────────────────────────────

contract MockRitualWallet {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lockUntil;

    function deposit(uint256 lockDuration) external payable {
        balanceOf[msg.sender] += msg.value;
        lockUntil[msg.sender] = block.number + lockDuration;
    }
}

// ──────────────────────────── TEEServiceRegistry ─────────────────────────

contract MockTEERegistry {
    address[] internal _services;

    /// Forces `found = false`, the "no executor available" path.
    bool public unavailable;

    function setServices(address[] calldata s) external {
        delete _services;
        for (uint256 i = 0; i < s.length; i++) _services.push(s[i]);
    }

    function setUnavailable(bool v) external {
        unavailable = v;
    }

    function serviceCount() external view returns (uint256) {
        return _services.length;
    }

    function pickServiceByCapability(
        uint8,
        bool,
        uint256 seed,
        uint256
    ) external view returns (address teeAddress, bool found) {
        if (unavailable || _services.length == 0) return (address(0), false);
        return (_services[seed % _services.length], true);
    }

    function getIndexedServiceCountByCapability(
        uint8
    ) external view returns (uint256) {
        return _services.length;
    }
}

// ─────────────────────────── HTTP precompile 0x0801 ──────────────────────

/**
 * Answers a raw `call` with the short-running async envelope
 * `(bytes simmedInput, bytes actualOutput)`, where `actualOutput` is the 5-field
 * HTTP response `(uint16, string[], string[], bytes, string)`.
 */
contract MockHttpPrecompile {
    uint8 public constant MODE_OK = 0;
    uint8 public constant MODE_REVERT = 1;
    uint8 public constant MODE_UNSETTLED = 2;
    uint8 public constant MODE_MALFORMED = 3;

    uint8 public mode;
    uint16 public status;
    bytes public body;
    string public errorMessage;

    // Recorded from the last request, so tests can assert what was actually sent.
    address public lastExecutor;
    string public lastUrl;
    uint256 public lastTtl;
    uint8 public lastMethod;
    uint256 public callCount;

    function setResponse(
        uint16 status_,
        bytes calldata body_,
        string calldata errorMessage_
    ) external {
        status = status_;
        body = body_;
        errorMessage = errorMessage_;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        if (mode == MODE_REVERT) revert("http executor unreachable");

        // The request is `abi.encode` of 13 values, so its head is 13 words and the
        // dynamic fields follow as offsets into the same blob. Two things rule out
        // the obvious `abi.decode`: decoding into a struct would expect a leading
        // offset word that a flat tuple encoding does not have, and decoding all 13
        // types at once runs the legacy codegen out of stack. Reading the three
        // fields under test straight out of the head sidesteps both.
        //
        //   word 0 executor · word 2 ttl · word 5 offset(url) · word 6 method
        address executor_;
        uint256 ttl_;
        uint8 method_;
        uint256 urlOffset;
        assembly {
            executor_ := calldataload(input.offset)
            ttl_ := calldataload(add(input.offset, 0x40))
            urlOffset := calldataload(add(input.offset, 0xA0))
            method_ := calldataload(add(input.offset, 0xC0))
        }

        uint256 urlLen;
        assembly {
            urlLen := calldataload(add(input.offset, urlOffset))
        }
        bytes memory urlBytes = input[urlOffset + 32:urlOffset + 32 + urlLen];

        lastExecutor = executor_;
        lastUrl = string(urlBytes);
        lastTtl = ttl_;
        lastMethod = method_;
        callCount++;

        if (mode == MODE_MALFORMED) {
            // Right shape at the outer level, garbage inside — this is what the
            // `try decodeHttpResponse` guard exists for.
            return abi.encode(bytes(""), bytes(hex"deadbeef"));
        }

        bytes memory actualOutput = mode == MODE_UNSETTLED
            ? bytes("")
            : abi.encode(
                status,
                new string[](0),
                new string[](0),
                body,
                errorMessage
            );

        return abi.encode(bytes(""), actualOutput);
    }
}

// ──────────────────────────── jq precompile 0x0803 ───────────────────────

/**
 * Reached through `staticcall`, so this fallback must never write storage.
 * Configure it before the call under test.
 */
contract MockJqPrecompile {
    uint256 public value;
    /// Returns a zero-length result, the way a wrong outputType does on chain.
    bool public returnsNothing;
    bool public reverts;

    function setValue(uint256 v) external {
        value = v;
    }

    function setReturnsNothing(bool v) external {
        returnsNothing = v;
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        if (reverts) revert("jq failed");

        (, , uint8 outputType) = abi.decode(input, (string, string, uint8));
        // A wrong outputType returns ok=true with a zero-length result on chain.
        if (returnsNothing || outputType != 1) return bytes("");

        return abi.encode(value);
    }
}
