// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPriceFeed {
    function centsPerGram() external view returns (uint256);
    function updatedAt() external view returns (uint64);
}

/// @title TradeEscrow — K-Gold 무역 에스크로
/// @notice 수입사가 무역 대금(달러)만큼의 KGOLD 를 잠그고, 수출사가 선적 서류를 올리면
///         수입사 결재선 3명 중 2명이 서명해서 정산한다. 정산할 때 그 시점의 금 시세로
///         대금에 해당하는 그램만 수출사에게 주고, 남는 건 수입사에게 돌려준다.
///
/// @dev 처음 만든 버전 세 개가 각각 깨진 곳 (반례: test/naive/)
///      01. 결재 서명이 서류에 묶여 있지 않았다 — 서명이 모인 뒤 서류를 바꿔도 같은 서명으로 정산됐다.
///          → 서명 내용에 dealId 와 docHash 를 넣는다. 서류는 한 번만 올릴 수 있다.
///      02. 기한이 지나면 수입사가 환불받을 수 있었다 — 결재선이 서명을 안 하고 기다리기만 하면
///          수출사가 물건을 보냈어도 돈이 돌아갔다.
///          → 기한 안에 서류가 올라왔으면 환불은 2-of-3 거절 서명(사유 해시 포함)으로만 된다.
///            검토 기간(14일) 동안 아무 답이 없으면 수출사가 정산을 요청할 수 있다.
///      03. 잠글 때의 시세로 지급량을 정했다 — 금값이 내리면 수출사가 대금보다 적게 받았다.
///          → 정산할 때 시세로 다시 계산한다. 잠근 양이 모자라면 정산을 보류하고 수입사가 추가로 넣어야 한다.
///            시세가 하루 넘게 안 바뀌었으면 그것도 보류한다.
contract TradeEscrow {
    uint256 public constant THRESHOLD = 2; // 결재선 3명 중 2명
    uint256 public constant LOCK_RATIO_PCT = 110; // 잠글 때 대금의 110% 이상
    uint256 public constant REVIEW_PERIOD = 14 days;
    uint256 public constant MAX_PRICE_AGE = 1 days;

    bytes32 public constant RELEASE_TYPEHASH = keccak256("Release(uint256 dealId,bytes32 docHash)");
    bytes32 public constant REJECT_TYPEHASH = keccak256("Reject(uint256 dealId,bytes32 docHash,bytes32 reasonHash)");
    // secp256k1 위수 n 의 절반 (지난 랩 ReserveOracle 과 같은 검사)
    uint256 private constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    struct Deal {
        address importer; // 수입사 (돈을 잠그는 쪽)
        address exporter; // 수출사 (물건을 보내는 쪽)
        address[3] approvers; // 수입사 결재선
        uint256 priceCents; // 무역 대금 (달러, 센트 단위)
        uint256 lockedMg; // 잠긴 KGOLD (밀리그램)
        uint64 deadline; // 선적 서류 제출 기한
        bytes32 docHash; // 선적 서류(B/L 등) 해시. 원본은 체인 밖에 있다
        uint64 docAt; // 서류를 올린 시각
        bool closed;
    }

    IERC20 public immutable token;
    IPriceFeed public immutable feed;
    bytes32 public immutable DOMAIN_SEPARATOR;

    Deal[] internal deals;

    event Created(uint256 indexed id, address indexed importer, address indexed exporter, uint256 priceCents, uint256 lockedMg);
    event ToppedUp(uint256 indexed id, uint256 addedMg);
    event DocumentSubmitted(uint256 indexed id, bytes32 docHash);
    event Settled(uint256 indexed id, uint256 paidMg, uint256 returnedMg, uint256 centsPerGram);
    event Rejected(uint256 indexed id, bytes32 reasonHash);
    event Refunded(uint256 indexed id, uint256 amountMg);

    constructor(IERC20 _token, IPriceFeed _feed) {
        token = _token;
        feed = _feed;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("K-Gold TradeEscrow"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ------------------------------------------------------------------
    // 수입사
    // ------------------------------------------------------------------

    function create(
        address exporter,
        address[3] calldata approvers,
        uint256 priceCents,
        uint256 lockedMg,
        uint64 deadline
    ) external returns (uint256 id) {
        require(deadline > block.timestamp, "BAD_DEADLINE");
        require(approvers[0] != address(0) && approvers[1] != address(0) && approvers[2] != address(0), "BAD_APPROVER");
        require(approvers[0] != approvers[1] && approvers[0] != approvers[2] && approvers[1] != approvers[2], "BAD_APPROVER");
        // 지금 시세 기준으로 대금의 110% 이상을 잠가야 한다. 금값이 조금 내려도 바로 보류되지 않게 하는 여유분이다.
        require(lockedMg * 100 >= requiredMg(priceCents) * LOCK_RATIO_PCT, "RATIO");

        id = deals.length;
        deals.push();
        Deal storage d = deals[id];
        d.importer = msg.sender;
        d.exporter = exporter;
        d.approvers = approvers;
        d.priceCents = priceCents;
        d.lockedMg = lockedMg;
        d.deadline = deadline;

        token.transferFrom(msg.sender, address(this), lockedMg);
        emit Created(id, msg.sender, exporter, priceCents, lockedMg);
    }

    /// 금값이 내려서 정산이 보류됐을 때 수입사가 KGOLD 를 더 넣는다.
    function topUp(uint256 id, uint256 addMg) external {
        Deal storage d = deals[id];
        require(msg.sender == d.importer, "NOT_IMPORTER");
        require(!d.closed, "CLOSED");
        d.lockedMg += addMg;
        token.transferFrom(msg.sender, address(this), addMg);
        emit ToppedUp(id, addMg);
    }

    /// 기한까지 서류가 안 올라왔을 때만 환불된다.
    function refund(uint256 id) external {
        Deal storage d = deals[id];
        require(msg.sender == d.importer, "NOT_IMPORTER");
        require(!d.closed, "CLOSED");
        require(d.docHash == bytes32(0), "DOC_SUBMITTED");
        require(block.timestamp > d.deadline, "NOT_EXPIRED");
        d.closed = true;
        token.transfer(d.importer, d.lockedMg);
        emit Refunded(id, d.lockedMg);
    }

    // ------------------------------------------------------------------
    // 수출사
    // ------------------------------------------------------------------

    /// 서류는 한 번만 올릴 수 있다. 바꾸고 싶으면 새 거래를 만들어야 한다.
    function submitDocument(uint256 id, bytes32 docHash) external {
        Deal storage d = deals[id];
        require(msg.sender == d.exporter, "NOT_EXPORTER");
        require(!d.closed, "CLOSED");
        require(docHash != bytes32(0), "EMPTY_DOC");
        require(d.docHash == bytes32(0), "DOC_SET");
        require(block.timestamp <= d.deadline, "TOO_LATE");
        d.docHash = docHash;
        d.docAt = uint64(block.timestamp);
        emit DocumentSubmitted(id, docHash);
    }

    /// 검토 기간이 끝날 때까지 결재선이 승인도 거절도 안 하면 수출사가 정산을 요청한다.
    function claimAfterReview(uint256 id) external {
        Deal storage d = deals[id];
        require(msg.sender == d.exporter, "NOT_EXPORTER");
        require(!d.closed, "CLOSED");
        require(d.docHash != bytes32(0), "NO_DOC");
        require(block.timestamp > d.docAt + REVIEW_PERIOD, "IN_REVIEW");
        _settle(id);
    }

    // ------------------------------------------------------------------
    // 결재선 (서명은 누가 제출해도 된다. 권한은 제출자가 아니라 서명에서 온다)
    // ------------------------------------------------------------------

    function release(uint256 id, bytes[] calldata signatures) external {
        Deal storage d = deals[id];
        require(!d.closed, "CLOSED");
        require(d.docHash != bytes32(0), "NO_DOC");
        _checkApprovals(d, releaseDigest(id), signatures);
        _settle(id);
    }

    /// 서류에 문제가 있으면 검토 기간 안에 2명이 거절한다. 사유 원문은 체인 밖에 두고 해시만 남긴다.
    function reject(uint256 id, bytes32 reasonHash, bytes[] calldata signatures) external {
        Deal storage d = deals[id];
        require(!d.closed, "CLOSED");
        require(d.docHash != bytes32(0), "NO_DOC");
        require(block.timestamp <= d.docAt + REVIEW_PERIOD, "REVIEW_OVER");
        _checkApprovals(d, rejectDigest(id, reasonHash), signatures);
        d.closed = true;
        token.transfer(d.importer, d.lockedMg);
        emit Rejected(id, reasonHash);
    }

    function releaseDigest(uint256 id) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(RELEASE_TYPEHASH, id, deals[id].docHash));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function rejectDigest(uint256 id, bytes32 reasonHash) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(REJECT_TYPEHASH, id, deals[id].docHash, reasonHash));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    // ------------------------------------------------------------------
    // 시세 · 정산
    // ------------------------------------------------------------------

    /// 대금을 지금 시세로 그램(mg)으로 바꾼다. 나머지는 올림해서 수출사가 1mg 이라도 덜 받지 않게 했다.
    function requiredMg(uint256 priceCents) public view returns (uint256) {
        require(block.timestamp - feed.updatedAt() <= MAX_PRICE_AGE, "STALE_PRICE");
        uint256 cpg = feed.centsPerGram();
        return (priceCents * 1000 + cpg - 1) / cpg;
    }

    function getDeal(uint256 id) external view returns (Deal memory) {
        return deals[id];
    }

    function _settle(uint256 id) internal {
        Deal storage d = deals[id];
        uint256 pay = requiredMg(d.priceCents);
        require(d.lockedMg >= pay, "UNDERCOLLATERALIZED");
        d.closed = true;

        uint256 rest = d.lockedMg - pay;
        token.transfer(d.exporter, pay);
        if (rest > 0) token.transfer(d.importer, rest);
        emit Settled(id, pay, rest, feed.centsPerGram());
    }

    /// 지난 랩 ReserveOracle 과 같은 방식이다. 서명자 주소가 오름차순이어야 해서 같은 사람이 두 번 들어갈 수 없다.
    function _checkApprovals(Deal storage d, bytes32 digest, bytes[] calldata signatures) internal view {
        require(signatures.length >= THRESHOLD, "QUORUM");
        address prev = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recover(digest, signatures[i]);
            require(signer > prev, "UNSORTED_OR_DUPLICATE");
            require(signer == d.approvers[0] || signer == d.approvers[1] || signer == d.approvers[2], "NOT_APPROVER");
            prev = signer;
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        require(sig.length == 65, "SIG_LENGTH");
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        require(uint256(s) <= HALF_N, "SIG_MALLEABLE");
        require(v == 27 || v == 28, "SIG_V");
        signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "SIG_INVALID");
    }
}
