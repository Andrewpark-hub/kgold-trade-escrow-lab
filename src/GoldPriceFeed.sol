// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title GoldPriceFeed — 금 1그램의 달러 가격 (센트 단위)
/// @notice 학습용이라 관리자 한 명이 값을 넣는다. 실제라면 Chainlink 같은 외부 시세 오라클 자리다.
///         지난 랩에서 토큰을 중량으로 정의해서 가격을 토큰 밖으로 뺐는데, 무역 대금은 달러로 정해지니까
///         결국 여기서 가격이 다시 필요해졌다.
///
/// @dev 값과 함께 갱신 시각을 저장한다. SEC 랩 02 에서 "오라클이 멈춰 있는지 모르면 거래를 허용한다" 는
///      문제를 봤기 때문에, 에스크로는 이 시각이 오래됐으면 정산을 보류한다.
contract GoldPriceFeed {
    address public immutable admin;
    uint256 public centsPerGram; // 예: 12,800 = 금 1g 에 128.00 달러
    uint64 public updatedAt;

    event PriceUpdated(uint256 centsPerGram, uint64 updatedAt);

    constructor(address _admin) {
        admin = _admin;
    }

    function setPrice(uint256 _centsPerGram) external {
        require(msg.sender == admin, "NOT_ADMIN");
        require(_centsPerGram > 0, "ZERO_PRICE");
        centsPerGram = _centsPerGram;
        updatedAt = uint64(block.timestamp);
        emit PriceUpdated(_centsPerGram, updatedAt);
    }
}
