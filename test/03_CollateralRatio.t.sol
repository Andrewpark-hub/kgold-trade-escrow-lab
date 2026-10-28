// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Base} from "./Base.t.sol";
import {IERC20, IPriceFeed} from "../src/TradeEscrow.sol";
import {NaiveLockPriceEscrow} from "./naive/NaiveLockPriceEscrow.sol";

contract CollateralRatioTest is Base {
    uint256 constant GOLD_DOWN_5 = 12_160; // 128.00 → 121.60 달러
    uint256 constant GOLD_DOWN_15 = 10_880; // 128.00 → 108.80 달러

    /// mg 단위 금을 그 시세의 센트로 바꾼다 (테스트에서 "몇 달러어치 받았나" 확인용)
    function _valueCents(uint256 mg, uint256 centsPerGram) internal pure returns (uint256) {
        return mg * centsPerGram / 1000;
    }

    // ------------------------------------------------------------------
    // [반례] 잠글 때 시세로 지급량을 정하는 에스크로
    // ------------------------------------------------------------------

    /// 잠글 때 10만 달러어치(781.25g)를 받아 둔다. 30일 뒤 금값이 15% 내린 상태에서 정산하면
    /// 수출사가 받는 금은 8만 5천 달러어치다.
    function test_Exploit_LockTimePriceUnderpaysExporter() public {
        NaiveLockPriceEscrow naive = new NaiveLockPriceEscrow(IERC20(address(token)), IPriceFeed(address(feed)));
        _register(address(naive));

        vm.prank(importer);
        (uint256 id, uint256 lockedMg) = naive.create(exporter, PRICE);
        assertEq(lockedMg, NEED, "locked exactly 100,000 dollars worth at lock time");

        vm.warp(block.timestamp + 30 days);
        _setPrice(GOLD_DOWN_15);
        vm.prank(importer);
        naive.release(id);

        assertEq(token.balanceOf(exporter), NEED, "same grams as at lock time");
        assertEq(_valueCents(token.balanceOf(exporter), GOLD_DOWN_15), 8_500_000, "but only 85,000 dollars worth");
    }

    // ------------------------------------------------------------------
    // 고친 에스크로
    // ------------------------------------------------------------------

    /// 금값이 5% 내렸으면 수출사에게 더 많은 그램을 준다. 110% 여유분 안이라 보류 없이 정산된다.
    function test_Fix_PaysByPriceAtSettlementAndReturnsRest() public {
        uint256 id = _create();
        _submit(id, DOC_A);
        _setPrice(GOLD_DOWN_5);
        uint256 before = token.balanceOf(importer);

        escrow.release(id, _signTwo(escrow.releaseDigest(id), 0, 1));

        uint256 paid = token.balanceOf(exporter);
        assertEq(paid, 822_369, "100,000 dollars / 121.60, rounded up");
        assertGe(_valueCents(paid, GOLD_DOWN_5), PRICE, "worth at least the price");
        assertEq(token.balanceOf(importer) - before, LOCK - paid, "rest goes back");
    }

    /// 금값이 15% 내리면 필요한 양(919,118mg)이 잠근 양(860,000mg)보다 많다. 정산을 보류한다.
    function test_Fix_PriceDropBelowBufferHoldsSettlement() public {
        uint256 id = _create();
        _submit(id, DOC_A);
        _setPrice(GOLD_DOWN_15);
        assertEq(escrow.requiredMg(PRICE), 919_118);

        bytes[] memory sigs = _signTwo(escrow.releaseDigest(id), 0, 1);
        vm.expectRevert("UNDERCOLLATERALIZED");
        escrow.release(id, sigs);
    }

    function test_Fix_TopUpUnlocksSettlement() public {
        uint256 id = _create();
        _submit(id, DOC_A);
        _setPrice(GOLD_DOWN_15);

        vm.prank(importer);
        escrow.topUp(id, 919_118 - LOCK);
        escrow.release(id, _signTwo(escrow.releaseDigest(id), 0, 1));

        assertEq(token.balanceOf(exporter), 919_118);
        assertGe(_valueCents(919_118, GOLD_DOWN_15), PRICE, "worth at least the price");
    }

    /// 시세가 하루 넘게 안 바뀌었으면 정산하지 않는다. 모를 때는 멈추는 쪽으로.
    function test_Fix_StalePriceHoldsSettlement() public {
        uint256 id = _create();
        _submit(id, DOC_A);
        bytes[] memory sigs = _signTwo(escrow.releaseDigest(id), 0, 1);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert("STALE_PRICE");
        escrow.release(id, sigs);

        _setPrice(GOLD);
        escrow.release(id, sigs);
        assertEq(token.balanceOf(exporter), NEED);
    }

    /// 110% 경계: 859,375mg 은 되고 1mg 적으면 안 된다.
    function test_Boundary_CreateNeedsTenPercentBuffer() public {
        uint64 deadline = uint64(block.timestamp + 60 days);

        vm.prank(importer);
        vm.expectRevert("RATIO");
        escrow.create(exporter, approvers, PRICE, 859_374, deadline);

        vm.prank(importer);
        escrow.create(exporter, approvers, PRICE, 859_375, deadline);
    }

    // ------------------------------------------------------------------
    // 고친 버전의 한계
    // ------------------------------------------------------------------

    /// 금값이 내린 뒤 수입사가 추가로 안 넣으면, 수출사는 서류를 냈어도 정산을 못 받는다.
    /// 수입사도 환불을 못 받지만 돈이 묶여 있는 동안 손해를 보는 건 물건을 이미 보낸 수출사다.
    function test_Limit_ImporterCanStallByNotToppingUp() public {
        uint256 id = _create();
        _submit(id, DOC_A);

        vm.warp(block.timestamp + 14 days + 1);
        _setPrice(GOLD_DOWN_15);

        vm.prank(exporter);
        vm.expectRevert("UNDERCOLLATERALIZED");
        escrow.claimAfterReview(id);

        vm.warp(block.timestamp + 60 days);
        vm.prank(importer);
        vm.expectRevert("DOC_SUBMITTED");
        escrow.refund(id);

        assertEq(token.balanceOf(address(escrow)), LOCK, "everything stuck in escrow");
        assertEq(token.balanceOf(exporter), 0);
    }

    /// 지난 랩의 회로차단기가 전송을 멈추면 에스크로도 정산·거절·환불이 전부 멈춘다.
    /// 에스크로 안의 금은 차단기와 상관없이 그대로 있는데도 그렇다.
    function test_Limit_BreakerPauseFreezesEscrow() public {
        uint256 id = _create();
        _submit(id, DOC_A);
        bytes[] memory sigs = _signTwo(escrow.releaseDigest(id), 0, 1);

        gate.set(true);
        vm.expectRevert("PAUSED");
        escrow.release(id, sigs);

        gate.set(false);
        escrow.release(id, sigs);
        assertEq(token.balanceOf(exporter), NEED);
    }
}
