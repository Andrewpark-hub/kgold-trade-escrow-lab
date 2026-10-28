// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Base} from "./Base.t.sol";
import {IERC20, TradeEscrow} from "../src/TradeEscrow.sol";
import {NaiveDeadlineEscrow} from "./naive/NaiveDeadlineEscrow.sol";

contract DeadlineTest is Base {
    event Rejected(uint256 indexed id, bytes32 reasonHash);

    bytes32 constant REASON = keccak256("quantity on B/L does not match purchase order");

    // ------------------------------------------------------------------
    // [반례] 기한이 지나면 무조건 환불되는 에스크로
    // ------------------------------------------------------------------

    /// 수출사는 50일째에 물건을 보내고 서류를 올렸다. 결재선은 아무것도 안 하고 기다린다.
    /// 61일째 수입사가 환불을 받는다. 수출사는 물건을 보냈는데 0 을 받는다.
    function test_Exploit_ImporterWaitsOutDeadline() public {
        NaiveDeadlineEscrow naive = new NaiveDeadlineEscrow(IERC20(address(token)));
        _register(address(naive));
        uint256 start = token.balanceOf(importer);

        vm.prank(importer);
        uint256 id = naive.create(exporter, approvers, NEED, uint64(block.timestamp + 60 days));

        vm.warp(block.timestamp + 50 days);
        vm.prank(exporter);
        naive.submitDocument(id, DOC_A);

        // --- 결재선은 서명하지 않는다 ---
        vm.warp(block.timestamp + 11 days);
        vm.prank(importer);
        naive.refund(id);

        assertEq(token.balanceOf(importer), start, "importer got everything back");
        assertEq(token.balanceOf(exporter), 0, "exporter shipped and got nothing");
    }

    // ------------------------------------------------------------------
    // 고친 에스크로
    // ------------------------------------------------------------------

    function test_Fix_DocumentBeforeDeadlineBlocksRefund() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 50 days);
        _submit(id, DOC_A);

        vm.warp(block.timestamp + 11 days);
        vm.prank(importer);
        vm.expectRevert("DOC_SUBMITTED");
        escrow.refund(id);
    }

    /// 서류가 안 올라왔으면 기한 다음 날 환불된다. 원래 설계의 "기한 초과 시 환불" 은 이 경우만 남았다.
    function test_Fix_NoDocumentByDeadlineRefunds() public {
        uint256 start = token.balanceOf(importer);
        uint256 id = _create();

        vm.warp(block.timestamp + 60 days);
        vm.prank(importer);
        vm.expectRevert("NOT_EXPIRED");
        escrow.refund(id);

        vm.warp(block.timestamp + 1);
        vm.prank(importer);
        escrow.refund(id);
        assertEq(token.balanceOf(importer), start, "full refund");
    }

    /// 환불을 받으려면 결재선 2명이 거절 사유에 서명해야 한다. 한 명으로는 안 된다.
    function test_Fix_RejectNeedsTwoAndLeavesReason() public {
        uint256 start = token.balanceOf(importer);
        uint256 id = _create();
        _submit(id, DOC_A);

        bytes[] memory one = new bytes[](1);
        one[0] = _sign(escrow.rejectDigest(id, REASON), approverKeys[0]);
        vm.expectRevert("QUORUM");
        escrow.reject(id, REASON, one);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit Rejected(id, REASON);
        escrow.reject(id, REASON, _signTwo(escrow.rejectDigest(id, REASON), 0, 1));

        assertEq(token.balanceOf(importer), start, "refunded by rejection");
        assertTrue(escrow.getDeal(id).closed);
    }

    /// 검토 기간 14일 동안 답이 없으면 수출사가 정산을 요청한다. 그 뒤에는 거절도 못 한다.
    function test_Fix_SilenceAfterReviewPaysExporter() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 50 days);
        _submit(id, DOC_A);

        vm.warp(block.timestamp + 14 days);
        _setPrice(GOLD); // 64일 동안 시세가 그대로면 낡은 값이라 다시 넣는다
        vm.prank(exporter);
        vm.expectRevert("IN_REVIEW");
        escrow.claimAfterReview(id);

        vm.warp(block.timestamp + 1);
        bytes[] memory sigs = _signTwo(escrow.rejectDigest(id, REASON), 0, 1);
        vm.expectRevert("REVIEW_OVER");
        escrow.reject(id, REASON, sigs);

        vm.prank(exporter);
        escrow.claimAfterReview(id);
        assertEq(token.balanceOf(exporter), NEED, "silence no longer helps the importer");
    }

    /// 기한 당일에 올린 서류는 받고, 1초 뒤에는 안 받는다.
    function test_Boundary_DocumentAtExactlyDeadline() public {
        uint256 id0 = _create();
        uint256 id1 = _create();
        TradeEscrow.Deal memory d = escrow.getDeal(id0);

        vm.warp(d.deadline);
        _submit(id0, DOC_A);

        vm.warp(d.deadline + 1);
        vm.prank(exporter);
        vm.expectRevert("TOO_LATE");
        escrow.submitDocument(id1, DOC_A);
    }
}
