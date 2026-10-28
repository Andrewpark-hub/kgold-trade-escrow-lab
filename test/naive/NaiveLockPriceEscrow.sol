// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20, IPriceFeed} from "../../src/TradeEscrow.sol";

/// @title [반례 03] 잠글 때의 시세로 지급량을 정하는 에스크로
/// @notice 대금이 10만 달러면, 잠글 때 시세로 "10만 달러어치 KGOLD" 를 계산해서 그만큼 받아 두고,
///         정산할 때 그대로 수출사에게 준다. 처음엔 이게 제일 자연스러워 보였다.
///
/// @dev 빠진 것: 잠근 뒤 정산까지 몇 주가 걸리는데, 그동안 금값이 움직인다. 금값이 15% 내리면
///      수출사가 받는 금은 8만 5천 달러어치가 된다. 지난 랩에서 토큰을 중량으로 정의해서 가격 위험을
///      토큰 밖으로 뺐는데, 그 위험이 그대로 수출사에게 넘어간 것이다.
///      (test_Exploit_LockTimePriceUnderpaysExporter)
///      결재·서류는 03 과 상관없어서 뺐다. 수입사가 직접 release 한다.
contract NaiveLockPriceEscrow {
    struct Deal {
        address importer;
        address exporter;
        uint256 lockedMg;
        bool closed;
    }

    IERC20 public immutable token;
    IPriceFeed public immutable feed;
    Deal[] internal deals;

    constructor(IERC20 _token, IPriceFeed _feed) {
        token = _token;
        feed = _feed;
    }

    function create(address exporter, uint256 priceCents) external returns (uint256 id, uint256 lockedMg) {
        lockedMg = priceCents * 1000 / feed.centsPerGram();
        id = deals.length;
        deals.push(Deal({importer: msg.sender, exporter: exporter, lockedMg: lockedMg, closed: false}));
        token.transferFrom(msg.sender, address(this), lockedMg);
    }

    function release(uint256 id) external {
        Deal storage d = deals[id];
        require(msg.sender == d.importer, "NOT_IMPORTER");
        require(!d.closed, "CLOSED");
        d.closed = true;
        token.transfer(d.exporter, d.lockedMg);
    }
}
