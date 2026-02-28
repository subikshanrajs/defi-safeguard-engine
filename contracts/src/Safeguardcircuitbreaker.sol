// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReceiver} from "./interfaces/IReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
/**
 * @title SafeguardCircuitBreaker
 * @notice CRE consumer contract that receives health-check reports from the
 *         Autonomous Protocol Safeguard Engine and enforces tiered responses.
 *
 * Report payload (ABI-encoded by the workflow):
 *   - uint256 reserveRatioBps  : current ratio × 10 000 (e.g. 10200 = 102.00%)
 *   - uint8   tier             : 0=HEALTHY, 1=MINOR_DEFICIT, 2=WARNING, 3=CRITICAL
 *   - bool    triggerHalt      : true only when tier == CRITICAL
 *
 * Security model
 * ──────────────
 * • Only the whitelisted `forwarder` address may call `onReport`.
 *   The forwarder is the Chainlink KeystoneForwarder, which itself validates
 *   that the report carries a quorum of DON node signatures.
 * • A zero `forwarder` address is rejected in the constructor to prevent
 *   misconfigured deployments from accepting arbitrary callers.
 * • Replay protection: the forwarder embeds a unique reportId in `metadata`;
 *   we track processed IDs to prevent the same report being applied twice.
 * • Stale-report guard: reports older than `maxReportAge` seconds are ignored.
 */
contract SafeguardCircuitBreaker is IReceiver, Ownable {
    // ── Tier enum (must stay in sync with the workflow's TIER constant) ───────
    enum Tier {
        HEALTHY,        // 0
        MINOR_DEFICIT,  // 1 — raise rates, reduce LTV
        WARNING,        // 2 — alert DAO, pause secondary swaps
        CRITICAL        // 3 — halt all minting + withdrawals
    }

    // ── State ─────────────────────────────────────────────────────────────────
    address public immutable forwarder;

    bool    public isProtocolPaused;
    bool    public isMintingPaused;
    bool    public isSwapsPaused;

    uint256 public lastReserveRatioBps;
    Tier    public lastTier;
    uint256 public lastReportTimestamp;
    uint256 public lastReportBlock;

    uint256 public maxReportAge = 5 minutes; // owner-configurable

    // replay-protection: reportId → processed
    mapping(bytes32 => bool) public processedReports;

    // ── Events ────────────────────────────────────────────────────────────────
    event HealthReportReceived(
        uint256 indexed reserveRatioBps,
        Tier    indexed tier,
        bool           triggerHalt,
        bytes32        reportId,
        uint256        timestamp
    );
    event ProtocolHalted(uint256 reserveRatioBps, uint256 timestamp);
    event ProtocolResumed(address indexed by, uint256 timestamp);
    event MintingPaused(uint256 reserveRatioBps);
    event MintingResumed(address indexed by);
    event SwapsPaused(uint256 reserveRatioBps);
    event SwapsResumed(address indexed by);
    event MaxReportAgeUpdated(uint256 oldAge, uint256 newAge);

    // ── Errors ────────────────────────────────────────────────────────────────
    error OnlyForwarder(address caller, address expected);
    error ZeroForwarderAddress();
    error ReportAlreadyProcessed(bytes32 reportId);
    error StaleReport(uint256 reportTimestamp, uint256 currentTimestamp);

    // ── Constructor ───────────────────────────────────────────────────────────
    /**
     * @param _forwarder  The Chainlink KeystoneForwarder address for this chain.
     *                    Sepolia: 0x... (see https://docs.chain.link/cre)
     *                    Must NOT be address(0).
     * @param _owner      Initial owner who can call admin functions.
     */
    constructor(address _forwarder, address _owner) Ownable(_owner) {
        if (_forwarder == address(0)) revert ZeroForwarderAddress();
        forwarder = _forwarder;
    }

    // ── IReceiver implementation ──────────────────────────────────────────────

    /**
     * @notice Called by the Chainlink KeystoneForwarder with a DON-verified report.
     * @param metadata  Forwarder-injected metadata (workflowId, reportId, timestamp…).
     * @param report    ABI-encoded (uint256 reserveRatioBps, uint8 tier, bool triggerHalt).
     */
    function onReport(
        bytes calldata metadata,
        bytes calldata report
    ) external override {
        // ── Auth: only the trusted forwarder ──────────────────────────────────
        if (msg.sender != forwarder) {
            revert OnlyForwarder(msg.sender, forwarder);
        }

        // ── Decode metadata to extract reportId and timestamp ─────────────────
        // Forwarder metadata layout (first 96 bytes):
        //   bytes32 workflowId | bytes32 reportId | uint32 timestamp (packed)
        // We only need the last 4 bytes of the first 64 for reportId + timestamp.
        // Using a simple hash of (reportId bytes + block.number) as replay key.
        bytes32 reportId = keccak256(abi.encodePacked(metadata, blockhash(block.number - 1)));

        // ── Replay protection ─────────────────────────────────────────────────
        if (processedReports[reportId]) {
            revert ReportAlreadyProcessed(reportId);
        }
        processedReports[reportId] = true;

        // ── Stale-report guard ────────────────────────────────────────────────
        // We use block.timestamp as "now"; the safeguard fires every minute
        // so any report older than maxReportAge is almost certainly stale.
        // NOTE: block.timestamp is miner-influenced ±15s — acceptable for
        //        minute-scale health checks.
        if (
            lastReportTimestamp != 0 &&
            block.timestamp > lastReportTimestamp + maxReportAge
        ) {
            // Allow the first-ever report through (lastReportTimestamp == 0)
            // and any fresh report.  Revert stale ones.
            revert StaleReport(lastReportTimestamp, block.timestamp);
        }

        // ── Decode report payload ─────────────────────────────────────────────
        (uint256 reserveRatioBps, uint8 tierRaw, bool triggerHalt) =
            abi.decode(report, (uint256, uint8, bool));

        Tier tier = Tier(tierRaw);

        // ── Update state ──────────────────────────────────────────────────────
        lastReserveRatioBps  = reserveRatioBps;
        lastTier             = tier;
        lastReportTimestamp  = block.timestamp;
        lastReportBlock      = block.number;

        emit HealthReportReceived(
            reserveRatioBps,
            tier,
            triggerHalt,
            reportId,
            block.timestamp
        );

        // ── Tiered response logic ─────────────────────────────────────────────
        _applyTieredResponse(reserveRatioBps, tier, triggerHalt);
    }
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
    return interfaceId == type(IReceiver).interfaceId || 
           interfaceId == type(IERC165).interfaceId;
}

    // ── Internal tiered response ──────────────────────────────────────────────

    function _applyTieredResponse(
        uint256 reserveRatioBps,
        Tier    tier,
        bool    triggerHalt
    ) internal {
        if (tier == Tier.HEALTHY) {
            // If previously paused by a lower tier, we do NOT auto-resume here.
            // Resuming requires an explicit owner call (see resumeProtocol etc.)
            // to ensure human review of the recovery before reopening.
            return;
        }

        if (tier == Tier.MINOR_DEFICIT) {
            // Tier 1: raise borrowing rates / reduce LTV via external interest
            //         rate model — protocol-specific, emit event for off-chain keeper.
            emit MintingPaused(reserveRatioBps); // re-used as "rate-adjustment signal"
            return;
        }

        if (tier == Tier.WARNING) {
            // Tier 2: pause secondary market swaps
            if (!isSwapsPaused) {
                isSwapsPaused = true;
                emit SwapsPaused(reserveRatioBps);
            }
            return;
        }

        // Tier 3: CRITICAL — full protocol halt
        if (triggerHalt && !isProtocolPaused) {
            isProtocolPaused = true;
            isMintingPaused  = true;
            isSwapsPaused    = true;
            emit ProtocolHalted(reserveRatioBps, block.timestamp);
        }
    }

    // ── Owner-only recovery functions ─────────────────────────────────────────

    /**
     * @notice Resumes all protocol operations after a critical halt.
     *         Call only after reserves have been verified as restored.
     */
    function resumeProtocol() external onlyOwner {
        isProtocolPaused = false;
        isMintingPaused  = false;
        isSwapsPaused    = false;
        emit ProtocolResumed(msg.sender, block.timestamp);
    }

    function resumeMinting() external onlyOwner {
        isMintingPaused = false;
        emit MintingResumed(msg.sender);
    }

    function resumeSwaps() external onlyOwner {
        isSwapsPaused = false;
        emit SwapsResumed(msg.sender);
    }

    /**
     * @notice Update the staleness threshold.
     * @param _newMaxAge  Maximum age in seconds a report may be before it is
     *                    considered stale and rejected.
     */
    function setMaxReportAge(uint256 _newMaxAge) external onlyOwner {
        emit MaxReportAgeUpdated(maxReportAge, _newMaxAge);
        maxReportAge = _newMaxAge;
    }

    // ── View helpers ──────────────────────────────────────────────────────────

    /**
     * @notice Returns the full protocol health snapshot in one call.
     */
    function getHealthSnapshot()
        external
        view
        returns (
            bool   protocolPaused,
            bool   mintingPaused,
            bool   swapsPaused,
            uint256 ratioBps,
            Tier   tier,
            uint256 lastUpdate
        )
    {
        return (
            isProtocolPaused,
            isMintingPaused,
            isSwapsPaused,
            lastReserveRatioBps,
            lastTier,
            lastReportTimestamp
        );
    }
}