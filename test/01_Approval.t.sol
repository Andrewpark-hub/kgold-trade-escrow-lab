// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Base} from "./Base.t.sol";
import {IERC20} from "../src/TradeEscrow.sol";
import {NaiveUnboundApprovalEscrow} from "./naive/NaiveUnboundApprovalEscrow.sol";

contract ApprovalTest is Base {
    // ------------------------------------------------------------------
    // [반례] 서명이 서류에 묶여 있지 않은 에스크로
    // ------------------------------------------------------------------

    /// 결재선은 서류 A(2,000개 선적)를 보고 서명했다. 서명이 모인 뒤 수출사가 서류를 B(200개)로 바꾼다.
    /// 같은 서명으로 정산이 되고, 체인에는 B 가 승인된 것으로 남는다.
    function test_Exploit_DocumentSwappedAfterApproval() public {
        NaiveUnboundApprovalEscrow naive = new NaiveUnboundApprovalEscrow(IERC20(address(token)));
        _register(address(naive));

        vm.prank(importer);
        uint256 id = naive.create(exporter, approvers, NEED);
        vm.prank(exporter);
        naive.submitDocument(id, DOC_A);

        bytes[] memory sigs = _signTwo(naive.releaseDigest(id), 0, 1); // A 를 보고 서명

        vm.prank(exporter);
        naive.submitDocument(id, DOC_B); // 서명이 모인 뒤 바꿔치기
        naive.release(id, sigs);

        assertEq(token.balanceOf(exporter), NEED, "settled with the same signatures");
        assertEq(naive.docHashOf(id), DOC_B, "chain says document B was approved");
    }

    // ------------------------------------------------------------------
    // 고친 에스크로
    // ------------------------------------------------------------------

    /// 기준선: 서류를 올리고 2명이 서명하면 대금만큼만 수출사에게 가고 나머지는 수입사에게 돌아온다.
    function test_Release_TwoOfThreeSettles() public {
        uint256 id = _create();
        _submit(id, DOC_A);
        uint256 before = token.balanceOf(importer);

        escrow.release(id, _signTwo(escrow.releaseDigest(id), 0, 2));

        assertEq(token.balanceOf(exporter), NEED, "exporter got exactly the price in gold");
        assertEq(token.balanceOf(importer) - before, LOCK - NEED, "buffer returned to importer");
        assertEq(token.balanceOf(address(escrow)), 0, "nothing left in escrow");
    }

    /// 결재선이 빨리 처리하려고 서류가 올라오기 전에 미리 서명해 뒀다. 그 뒤 수출사가 서류 B 를 올린다.
    /// 서명 내용에 docHash 가 들어가므로, 서류 없이 한 서명은 B 에 대한 승인이 되지 않는다.
    /// (처음 쓴 테스트는 서명 내용을 테스트 안에서 직접 만들어서, docHash 검사를 지워도 통과했다. README 트러블슈팅 참고)
    function test_Fix_PresignedApprovalDoesNotCoverLaterDocument() public {
        uint256 id = _create();
        bytes[] memory sigs = _signTwo(escrow.releaseDigest(id), 0, 1); // 서류가 아직 없을 때의 digest

        _submit(id, DOC_B);

        // 다른 내용에서 복원한 주소는 결재선이 아니다
        vm.expectRevert("NOT_APPROVER");
        escrow.release(id, sigs);
    }

    function test_Fix_DocumentCannotBeReplaced() public {
        uint256 id = _create();
        _submit(id, DOC_A);

        vm.prank(exporter);
        vm.expectRevert("DOC_SET");
        escrow.submitDocument(id, DOC_B);
    }

    /// 설계 문서의 "단독 결재 우회" — 결재선 한 명이 자기 서명을 두 번 넣는다.
    function test_Fix_OneApproverTwiceRejected() public {
        uint256 id = _create();
        _submit(id, DOC_A);

        bytes memory sig = _sign(escrow.releaseDigest(id), approverKeys[0]);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (sig, sig);

        vm.expectRevert("UNSORTED_OR_DUPLICATE");
        escrow.release(id, sigs);
    }

    /// 같은 수출사가 두 거래에 같은 서류 해시를 올렸다. 거래 0 에 한 서명을 거래 1 에 쓸 수는 없다.
    function test_Fix_SignatureForOtherDealRejected() public {
        uint256 id0 = _create();
        uint256 id1 = _create();
        _submit(id0, DOC_A);
        _submit(id1, DOC_A);

        bytes[] memory sigsFor0 = _signTwo(escrow.releaseDigest(id0), 0, 1);

        vm.expectRevert("NOT_APPROVER");
        escrow.release(id1, sigsFor0);
    }
}
