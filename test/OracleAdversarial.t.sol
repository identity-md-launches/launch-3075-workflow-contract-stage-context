// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleFixture} from "./helpers/OracleFixture.sol";
import {BoundaryOracle} from "src/BoundaryOracle.sol";
import {BoundaryProofVerifier} from "src/BoundaryProofVerifier.sol";
import {MarketTypes as T} from "src/libraries/MarketTypes.sol";

/// forge-config: default.fuzz.runs = 512
contract OracleAdversarialTest is OracleFixture {
    function _snapshot(bytes32 id) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                oracle.proposal(id),
                oracle.price(1, BOUNDARY),
                oracle.latestBoundary(1),
                oracle.credit(proposer),
                oracle.credit(challenger),
                oracle.credit(sponsor),
                imd.balanceOf(address(oracle)),
                imd.balanceOf(address(intake)),
                imd.balanceOf(proposer),
                imd.balanceOf(challenger),
                imd.balanceOf(sponsor),
                intake.nonce()
            )
        );
    }

    function test_proofAndProposalWindowsMeetWithoutOverlap() public {
        vm.warp(BOUNDARY + 27 hours);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        BoundaryProofVerifier.BlockProof[3] memory proof;
        oracle.prove(1, BOUNDARY, proof);
        assertEq(oracle.price(1, BOUNDARY), 1e18);
        vm.warp(BOUNDARY + 27 hours + 1);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 2e18, FIRST_BLOCK);
    }

    function test_oneSecondBeforeAndAtLatestProposalTime() public {
        vm.warp(BOUNDARY + 3 days - 1 hours);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        assertEq(imd.balanceOf(address(oracle)), 0);
        vm.warp(BOUNDARY + 3 days - 1 hours - 1);
        bytes32 id = _propose(1e18);
        vm.warp(oracle.proposal(id).deadline);
        oracle.finalize(1, BOUNDARY);
        assertEq(oracle.price(1, BOUNDARY), 1e18);
        assertEq(oracle.credit(proposer), 10e18);
    }

    function test_disputeAtDeadlineFailsButFinalizationSucceeds() public {
        bytes32 id = _propose(2e18);
        vm.warp(oracle.proposal(id).deadline);
        bytes32 beforeState = _snapshot(id);
        vm.prank(challenger);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.dispute(1, BOUNDARY, 1e18);
        assertEq(_snapshot(id), beforeState);
        oracle.finalize(1, BOUNDARY);
        assertEq(oracle.credit(proposer), 10e18);
    }

    function test_atTimeoutUncontestedBondRefundsWithoutRecordingLatePrice() public {
        bytes32 id = _propose(2e18);
        vm.warp(BOUNDARY + 3 days);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.finalize(1, BOUNDARY);
        oracle.timeout(1, BOUNDARY);
        assertTrue(oracle.proposal(id).finished);
        assertEq(oracle.price(1, BOUNDARY), 0);
        assertEq(oracle.credit(proposer), 10e18);
    }

    function test_invalidProposalValuesAndBlockWindowNeverPullBond() public {
        bytes32 id = oracle.proposalId(1, BOUNDARY);
        bytes32 beforeState = _snapshot(id);
        for (uint8 fault; fault < 5; ++fault) {
            uint256 value = fault == 0 ? 0 : fault == 1 ? T.MAX_PRICE + 1 : 1e18;
            uint64 first = fault == 2 ? 0 : fault == 3 ? uint64(block.number - 2) : FIRST_BLOCK;
            uint64 boundary = fault == 4 ? BOUNDARY + 1 : BOUNDARY;
            vm.prank(proposer);
            vm.expectRevert(BoundaryOracle.InvalidState.selector);
            oracle.propose(1, boundary, value, first);
            assertEq(_snapshot(id), beforeState);
        }
    }

    function test_foreignChainCannotProposeOrProve() public {
        vm.chainId(10);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        vm.warp(BOUNDARY + 1);
        BoundaryProofVerifier.BlockProof[3] memory proof;
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, BOUNDARY, proof);
        assertEq(imd.balanceOf(address(oracle)), 0);
    }

    function test_selfDisputeDuplicateDisputeAndExcessBudgetAreAtomic() public {
        bytes32 id = _propose(1e18);
        bytes32 beforeState = _snapshot(id);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.dispute(1, BOUNDARY, 1e18);
        vm.prank(challenger);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.dispute(1, BOUNDARY, 10e18 + 1);
        assertEq(_snapshot(id), beforeState);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, 1e18);
        beforeState = _snapshot(id);
        vm.prank(sponsor);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.dispute(1, BOUNDARY, 1e18);
        vm.prank(sponsor);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.retryResolution(1, BOUNDARY, 1e18);
        assertEq(_snapshot(id), beforeState);
    }

    function test_taxedBondAndFailedTransferCannotLeaveProposalOrChallenge() public {
        bytes32 id = oracle.proposalId(1, BOUNDARY);
        bytes32 beforeState = _snapshot(id);
        imd.configure(false, true);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        assertEq(_snapshot(id), beforeState);
        imd.configure(false, false);
        _propose(1e18);
        beforeState = _snapshot(id);
        imd.configure(true, false);
        vm.prank(challenger);
        vm.expectRevert(bytes("transfer rejected"));
        oracle.dispute(1, BOUNDARY, 1e18);
        assertEq(_snapshot(id), beforeState);
    }

    function test_creditWithdrawalFailureAndReentrancyPreserveSinglePayment() public {
        bytes32 id = _propose(2e18);
        vm.warp(oracle.proposal(id).deadline);
        oracle.finalize(1, BOUNDARY);
        imd.configure(true, false);
        vm.prank(proposer);
        vm.expectRevert(bytes("transfer rejected"));
        oracle.withdrawCredit();
        assertEq(oracle.credit(proposer), 10e18);
        imd.configure(false, false);
        imd.setCallback(address(oracle), abi.encodeCall(oracle.withdrawCredit, ()));
        vm.prank(proposer);
        oracle.withdrawCredit();
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(oracle.credit(proposer), 0);
        assertEq(imd.balanceOf(proposer), 10_000e18);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.withdrawCredit();
    }

    function test_thirdPartySponsorGetsOnlyActualSuccessfulCostBack() public {
        bytes32 id = _propose(2e18);
        intake.configure(0.5e18, false, true);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, 3e18);
        assertEq(oracle.credit(challenger), 3e18);
        vm.prank(sponsor);
        oracle.retryResolution(1, BOUNDARY, 0.5e18);
        assertEq(oracle.credit(sponsor), 0.5e18);
        intake.configure(0.5e18, false, false);
        vm.prank(sponsor);
        oracle.retryResolution(1, BOUNDARY, 2e18);
        assertEq(oracle.credit(sponsor), 1.5e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[0], 1000e18);
        _deliver(p.requests[1], 2000e6);
        assertEq(oracle.credit(proposer), 19e18);
        assertEq(oracle.credit(challenger), 3e18);
        assertEq(oracle.credit(sponsor), 2.5e18);
        assertEq(imd.balanceOf(address(oracle)), 24.5e18);
        assertEq(imd.balanceOf(address(intake)), 1e18);
    }

    function test_partialAnswerThenFailureRefundsBondsAndRejectsLateAnswer() public {
        bytes32 id = _disputed(2e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[0], 1000e18);
        vm.prank(address(intake));
        oracle.onFailure(p.requests[1], 1, bytes32(0), 5, 0, "");
        assertEq(oracle.credit(proposer), 10e18);
        assertEq(oracle.credit(challenger), 10e18);
        assertEq(oracle.price(1, BOUNDARY), 0);
        BoundaryOracle.Attestation memory a = _answer(p.requests[1], 2000e6);
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(p.requests[1], a, sig);
    }

    function test_invalidFailureStatusDoesNotTerminatePendingRequests() public {
        bytes32 id = _disputed(2e18);
        bytes32 beforeState = _snapshot(id);
        bytes32 rid = oracle.proposal(id).requests[0];
        for (uint8 status; status < 4; ++status) {
            if (status == 1 || status == 2) continue;
            vm.prank(address(intake));
            vm.expectRevert(BoundaryOracle.InvalidState.selector);
            oracle.onFailure(rid, status, bytes32(0), 5, 0, "");
        }
        assertEq(_snapshot(id), beforeState);
        (,,, bool pending) = oracle.requests(rid);
        assertTrue(pending);
    }

    function test_signedMalformedAnswersDoNotConsumeRequestOrAttestation() public {
        bytes32 id = _disputed(2e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        bytes32 beforeState = _snapshot(id);
        for (uint8 fault; fault < 9; ++fault) {
            BoundaryOracle.Attestation memory a = _answer(rid, 1000e18);
            if (fault == 0) a.requestId = bytes32(0);
            if (fault == 1) a.answer = new bytes(31);
            if (fault == 2) a.answer = new bytes(33);
            if (fault == 3) a.answer = abi.encode(uint256(0));
            if (fault == 4) a.toBlock += 1;
            if (fault == 5) a.blockHash = bytes32(0);
            if (fault == 6) a.issuedAt = oracle.proposal(id).deadline - 1 hours - 1;
            if (fault == 7) a.quorum = 6;
            if (fault == 8) a.expiresAt = a.issuedAt - 1;
            bytes memory sig = _signature(a);
            vm.prank(address(intake));
            vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
            oracle.onOracleResult(rid, a, sig);
            assertEq(_snapshot(id), beforeState);
            assertFalse(oracle.usedAttestations(a.requestId));
            (,,, bool pending) = oracle.requests(rid);
            assertTrue(pending);
        }
        _deliver(rid, 1000e18);
        assertEq(oracle.proposal(id).received, 1);
    }

    function test_attestationUuidCannotBeReusedForAnotherPoolEvenIfSigned() public {
        bytes32 id = _disputed(2e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[0], 1000e18);
        BoundaryOracle.Attestation memory a = _answer(p.requests[1], 2000e6);
        a.requestId = _answer(p.requests[0], 1000e18).requestId;
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
        oracle.onOracleResult(p.requests[1], a, sig);
        assertEq(oracle.proposal(id).received, 1);
        _deliver(p.requests[1], 2000e6);
        assertEq(oracle.price(1, BOUNDARY), 2e18);
    }

    function test_signatureForDifferentConsumerIsInvalid() public {
        bytes32 id = _disputed(2e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        BoundaryOracle.Attestation memory a = _answer(rid, 1000e18);
        BoundaryOracle other = new BoundaryOracle(registry, BoundaryProofVerifier(address(verifier)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FIXTURE_KEY, other.digest(a));
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
        oracle.onOracleResult(rid, a, abi.encodePacked(r, s, v));
        assertEq(oracle.proposal(id).received, 0);
    }

    function test_answerAtTimeoutRejectedButBondsStillRecoverable() public {
        bytes32 id = _disputed(2e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        vm.warp(BOUNDARY + 3 days);
        BoundaryOracle.Attestation memory a = _answer(rid, 1000e18);
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
        oracle.onOracleResult(rid, a, sig);
        oracle.timeout(1, BOUNDARY);
        assertEq(oracle.credit(proposer), 10e18);
        assertEq(oracle.credit(challenger), 10e18);
    }

    function testFuzz_unusedDisputeBudgetIsRefundedExactly(uint64 rawBudget, bool correct) public {
        uint256 maximum = bound(rawBudget, 1e18, 10e18);
        bytes32 id = _propose(correct ? 2e18 : 1e18);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, maximum);
        assertEq(oracle.credit(challenger), maximum - 1e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[1], 2000e6);
        _deliver(p.requests[0], 1000e18);
        assertEq(oracle.credit(proposer), correct ? 19e18 : 0);
        assertEq(oracle.credit(challenger), correct ? maximum : maximum + 19e18);
        assertEq(imd.balanceOf(address(oracle)), oracle.credit(proposer) + oracle.credit(challenger));
    }
}
