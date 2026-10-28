// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {KGold, ITransferGate} from "../src/KGold.sol";
import {GoldPriceFeed} from "../src/GoldPriceFeed.sol";
import {TradeEscrow, IERC20, IPriceFeed} from "../src/TradeEscrow.sol";

/// 지난 랩의 회로차단기 대신 쓰는 스위치. 전송 정지를 켜고 끌 수만 있다.
contract MockGate is ITransferGate {
    bool public transfersPaused;

    function set(bool paused) external {
        transfersPaused = paused;
    }
}

/// 토큰 · 시세 · 에스크로 배포 + 결재선 서명 헬퍼
abstract contract Base is Test {
    address admin = makeAddr("admin"); // K-Gold 운영 (토큰 관리 · 발행 · 시세 입력)
    address importer = makeAddr("importer"); // 수입사 A
    address exporter = makeAddr("exporter"); // 수출사 B

    // 수입사 결재선 3명의 개인키 (vm.sign 용)
    uint256[3] approverKeys;
    address[3] approvers;

    KGold token;
    MockGate gate;
    GoldPriceFeed feed;
    TradeEscrow escrow;

    uint256 constant PRICE = 10_000_000; // 무역 대금 10만 달러 (센트)
    uint256 constant GOLD = 12_800; // 금 1g = 128.00 달러 (센트)
    uint256 constant NEED = 781_250; // 10만 달러 / 128달러 = 781.25g = 781,250mg
    uint256 constant LOCK = 860_000; // 110% 인 859,375mg 보다 조금 많이 잠근다

    bytes32 constant DOC_A = keccak256("B/L KGX-0042: 2,000 units, shipped 2026-10-20");
    bytes32 constant DOC_B = keccak256("B/L KGX-0042: 200 units, shipped 2026-10-20");

    function setUp() public virtual {
        vm.warp(1_790_000_000);

        for (uint256 i = 0; i < 3; i++) {
            (approvers[i], approverKeys[i]) = makeAddrAndKey(string.concat("approver", vm.toString(i + 1)));
        }

        vm.startPrank(admin);
        token = new KGold(admin);
        gate = new MockGate();
        token.wire(admin, gate); // 발행 담당을 admin 으로 둔다 (MintController 는 지난 랩에서 확인함)
        feed = new GoldPriceFeed(admin);
        feed.setPrice(GOLD);
        escrow = new TradeEscrow(IERC20(address(token)), IPriceFeed(address(feed)));

        token.setRegistered(importer, true);
        token.setRegistered(exporter, true);
        token.setRegistered(address(escrow), true); // 등록 기업끼리만 전송되므로 에스크로도 등록해야 한다
        token.mint(importer, 10_000_000); // 수입사에게 금 10kg
        vm.stopPrank();

        vm.prank(importer);
        token.approve(address(escrow), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // 거래 헬퍼
    // ------------------------------------------------------------------

    /// 기한 60일짜리 거래를 만든다
    function _create() internal returns (uint256 id) {
        vm.prank(importer);
        id = escrow.create(exporter, approvers, PRICE, LOCK, uint64(block.timestamp + 60 days));
    }

    function _submit(uint256 id, bytes32 docHash) internal {
        vm.prank(exporter);
        escrow.submitDocument(id, docHash);
    }

    /// 시세 피드는 하루가 지나면 낡은 값이 되므로, 시간을 많이 넘긴 테스트는 정산 전에 다시 넣는다
    function _setPrice(uint256 centsPerGram) internal {
        vm.prank(admin);
        feed.setPrice(centsPerGram);
    }

    function _register(address who) internal {
        vm.prank(admin);
        token.setRegistered(who, true);
        vm.prank(importer);
        token.approve(who, type(uint256).max);
    }

    // ------------------------------------------------------------------
    // 서명 헬퍼
    // ------------------------------------------------------------------

    function _sign(bytes32 digest, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// 결재선 a, b 두 명의 서명을 주소 오름차순으로 돌려준다 (에스크로가 정렬을 요구한다)
    function _signTwo(bytes32 digest, uint256 a, uint256 b) internal view returns (bytes[] memory sigs) {
        if (approvers[a] > approvers[b]) (a, b) = (b, a);
        sigs = new bytes[](2);
        sigs[0] = _sign(digest, approverKeys[a]);
        sigs[1] = _sign(digest, approverKeys[b]);
    }
}
