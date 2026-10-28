// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "../../src/TradeEscrow.sol";

/// @title [반례 01] 결재 서명이 서류에 묶여 있지 않은 에스크로
/// @notice 결재선이 "거래 #id 를 정산해도 된다" 에 서명한다. 서명자 정렬·중복 검사는 지난 랩의
///         오라클처럼 제대로 넣었다. 처음엔 이걸로 2-of-3 이 다 된 줄 알았다.
///
/// @dev 빠진 것: 서명 내용에 서류 해시가 없다. 그리고 수출사가 서류를 다시 올릴 수 있다.
///      결재선이 서류 A 를 보고 서명한 뒤, 수출사가 서류를 B 로 바꿔도 같은 서명으로 정산된다.
///      체인에는 "B 가 승인됐다" 로 남는다. (test_Exploit_DocumentSwappedAfterApproval)
///      시세·담보 비율은 01 과 상관없어서 뺐다. 잠근 양을 전부 수출사에게 준다.
contract NaiveUnboundApprovalEscrow {
    struct Deal {
        address importer;
        address exporter;
        address[3] approvers;
        uint256 lockedMg;
        bytes32 docHash;
        bool closed;
    }

    IERC20 public immutable token;
    Deal[] internal deals;

    constructor(IERC20 _token) {
        token = _token;
    }

    function create(address exporter, address[3] calldata approvers, uint256 lockedMg) external returns (uint256 id) {
        id = deals.length;
        deals.push();
        Deal storage d = deals[id];
        d.importer = msg.sender;
        d.exporter = exporter;
        d.approvers = approvers;
        d.lockedMg = lockedMg;
        token.transferFrom(msg.sender, address(this), lockedMg);
    }

    /// 서류를 잘못 올렸을 때 고칠 수 있게 하려고 덮어쓰기를 허용했다.
    function submitDocument(uint256 id, bytes32 docHash) external {
        require(msg.sender == deals[id].exporter, "NOT_EXPORTER");
        deals[id].docHash = docHash;
    }

    function releaseDigest(uint256 id) public pure returns (bytes32) {
        return keccak256(abi.encode("RELEASE", id));
    }

    function release(uint256 id, bytes[] calldata sigs) external {
        Deal storage d = deals[id];
        require(!d.closed, "CLOSED");
        require(d.docHash != bytes32(0), "NO_DOC");
        require(sigs.length >= 2, "QUORUM");
        address prev = address(0);
        for (uint256 i = 0; i < sigs.length; i++) {
            address signer = ecrecover(releaseDigest(id), uint8(sigs[i][64]), bytes32(sigs[i][0:32]), bytes32(sigs[i][32:64]));
            require(signer > prev, "UNSORTED_OR_DUPLICATE");
            require(signer == d.approvers[0] || signer == d.approvers[1] || signer == d.approvers[2], "NOT_APPROVER");
            prev = signer;
        }
        d.closed = true;
        token.transfer(d.exporter, d.lockedMg);
    }

    function docHashOf(uint256 id) external view returns (bytes32) {
        return deals[id].docHash;
    }
}
