// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "../../src/TradeEscrow.sol";

/// @title [반례 02] 기한이 지나면 수입사가 환불받는 에스크로
/// @notice K-Gold 설계 문서의 "기한 초과 시 환불" 을 그대로 옮겼다. 결재는 결재선이 직접
///         approve() 를 부르는 방식으로 단순하게 했다(02 는 서명 방식과 상관없다).
///
/// @dev 빠진 것: 기한 안에 수출사가 서류를 올렸는지를 안 본다. 그러면 결재선은 서명을 안 하고
///      기다리기만 하면 된다. 기한이 지나면 수입사가 전액 환불받고, 수출사는 물건을 보냈는데 아무것도
///      못 받는다. 결재와 환불을 둘 다 수입사 쪽이 쥐고 있어서 생긴 문제다.
///      (test_Exploit_ImporterWaitsOutDeadline)
contract NaiveDeadlineEscrow {
    struct Deal {
        address importer;
        address exporter;
        address[3] approvers;
        uint256 lockedMg;
        uint64 deadline;
        bytes32 docHash;
        uint256 approvals;
        bool closed;
    }

    IERC20 public immutable token;
    Deal[] internal deals;
    mapping(uint256 => mapping(address => bool)) public approved;

    constructor(IERC20 _token) {
        token = _token;
    }

    function create(address exporter, address[3] calldata approvers, uint256 lockedMg, uint64 deadline)
        external
        returns (uint256 id)
    {
        id = deals.length;
        deals.push();
        Deal storage d = deals[id];
        d.importer = msg.sender;
        d.exporter = exporter;
        d.approvers = approvers;
        d.lockedMg = lockedMg;
        d.deadline = deadline;
        token.transferFrom(msg.sender, address(this), lockedMg);
    }

    function submitDocument(uint256 id, bytes32 docHash) external {
        require(msg.sender == deals[id].exporter, "NOT_EXPORTER");
        require(block.timestamp <= deals[id].deadline, "TOO_LATE");
        deals[id].docHash = docHash;
    }

    function approve(uint256 id) external {
        Deal storage d = deals[id];
        require(msg.sender == d.approvers[0] || msg.sender == d.approvers[1] || msg.sender == d.approvers[2], "NOT_APPROVER");
        require(!approved[id][msg.sender], "APPROVED");
        approved[id][msg.sender] = true;
        d.approvals++;
        if (d.approvals >= 2 && d.docHash != bytes32(0) && !d.closed) {
            d.closed = true;
            token.transfer(d.exporter, d.lockedMg);
        }
    }

    function refund(uint256 id) external {
        Deal storage d = deals[id];
        require(msg.sender == d.importer, "NOT_IMPORTER");
        require(!d.closed, "CLOSED");
        require(block.timestamp > d.deadline, "NOT_EXPIRED");
        d.closed = true;
        token.transfer(d.importer, d.lockedMg);
    }
}
