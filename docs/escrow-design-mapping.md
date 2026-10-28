# K-Gold 무역 에스크로 설계 → 컨트랙트 매핑

출처: K-Gold 설계(핀테크 아이디어 공모전), 지난 저장소 [kgold-reserve-breaker-lab](https://github.com/Andrewpark-hub/kgold-reserve-breaker-lab)의 `docs/kgold-design-mapping.md` 에서 "❌ 다음 과제" 로 남겨 둔 항목들

> 이 문서는 지난 저장소에서 미뤄 둔 에스크로 관련 항목을 이번에 무엇으로 만들었고 무엇을 남겼는지 정리한 것이다.
> 실제 은행·무역보험·선적 서류 시스템과는 연동하지 않았다. 설계 문장을 코드로 옮길 때 어디서 깨지는지 보려고 만든 최소 예제다.

## 지난 저장소에서 넘어온 항목

| 지난 매핑 문서의 항목 | 그때 상태 | 이번 저장소 |
|---|---|---|
| 무역 에스크로 (담보 잠금, 결재선 2-of-3 승인 시 정산, 기한 초과 시 환불) | ❌ 다음 과제 | ✅ `TradeEscrow.sol`. 단, "기한 초과 시 환불" 은 서류가 안 올라온 경우에만 남겼다 (반례 02) |
| 담보 비율 미달 → 해당 계약 정산 보류 | ⚠️ 토큰 전체 기준으로만 구현 | ✅ 거래별로 정산할 때 시세로 다시 계산, 모자라면 `UNDERCOLLATERALIZED` |
| 단독 결재 우회 | ❌ 에스크로 미구현 | ✅ `test_Fix_OneApproverTwiceRejected` |
| 기한 경계 조건 | 에스크로 기한은 미구현 | ✅ `test_Boundary_DocumentAtExactlyDeadline` |
| MPC 지갑 · 계정 추상화 (기업 내부 다중 서명) | ❌ 범위 밖, 결재선 EIP-712 다중 승인으로 대신할 계획 | ⚠️ 계획대로 EIP-712 2-of-3 서명으로 대신했다. MPC·AA 는 여전히 범위 밖 |
| 가격 위험 ("중량 기준으로 바꿔 토큰에서 가격을 뺐다, 가격 위험은 에스크로로 이동") | 미구현 | ✅ `GoldPriceFeed` + 정산 시점 재계산 (반례 03) |

## 처음 만든 버전 → 깨진 곳 → 고친 것

| # | 처음 만든 버전 | 깨지는 것을 보인 테스트 | 고친 것 | 고친 것을 확인한 테스트 |
|---|---|---|---|---|
| 01 | 결재선이 `거래 #id 정산` 에 서명, 서류는 덮어쓰기 가능 | `test_Exploit_DocumentSwappedAfterApproval` | 서명 내용에 `dealId`, `docHash` 를 넣고 서류는 한 번만 | `test_Fix_PresignedApprovalDoesNotCoverLaterDocument`, `test_Fix_DocumentCannotBeReplaced`, `test_Fix_SignatureForOtherDealRejected` |
| 02 | 기한이 지나면 수입사 환불 | `test_Exploit_ImporterWaitsOutDeadline` | 서류가 올라왔으면 2-of-3 거절 서명으로만 환불, 14일 동안 답이 없으면 수출사가 정산 요청 | `test_Fix_DocumentBeforeDeadlineBlocksRefund`, `test_Fix_RejectNeedsTwoAndLeavesReason`, `test_Fix_SilenceAfterReviewPaysExporter` |
| 03 | 잠글 때 시세로 지급량 고정 | `test_Exploit_LockTimePriceUnderpaysExporter` | 110% 잠그고 정산할 때 시세로 다시 계산, 모자라면 보류, 시세가 하루 넘게 낡았으면 보류 | `test_Fix_PaysByPriceAtSettlementAndReturnsRest`, `test_Fix_PriceDropBelowBufferHoldsSettlement`, `test_Fix_TopUpUnlocksSettlement`, `test_Fix_StalePriceHoldsSettlement` |

## 검사를 하나씩 지워 본 결과

테스트가 정말 무언가를 검사하는지 확인하려고 `TradeEscrow.sol` 의 검사를 하나씩 지우고 `forge test` 를 돌렸다.

| 지운 검사 | 실패한 테스트 |
|---|---|
| 서명 내용에서 `docHash` | `test_Fix_PresignedApprovalDoesNotCoverLaterDocument` (처음 쓴 테스트는 실패하지 않았다. README 트러블슈팅 참고) |
| 서명 내용에서 `dealId` | `test_Fix_SignatureForOtherDealRejected` |
| 서류 덮어쓰기 금지 (`DOC_SET`) | `test_Fix_DocumentCannotBeReplaced` |
| 환불할 때 서류 확인 (`DOC_SUBMITTED`) | `test_Fix_DocumentBeforeDeadlineBlocksRefund`, `test_Limit_ImporterCanStallByNotToppingUp` |
| 담보 부족 검사 (`UNDERCOLLATERALIZED`) | `test_Fix_PriceDropBelowBufferHoldsSettlement`, `test_Limit_ImporterCanStallByNotToppingUp` |
| 시세 만료 검사 (`STALE_PRICE`) | `test_Fix_StalePriceHoldsSettlement` |
| 그램 환산 올림 → 내림 | `test_Fix_PaysByPriceAtSettlementAndReturnsRest` 외 2개 |
| 검토 기간 끝 확인 (`REVIEW_OVER`) | `test_Fix_SilenceAfterReviewPaysExporter` |

## 고친 버전의 한계

| 한계 | 테스트 | 메모 |
|---|---|---|
| 금값이 내린 뒤 수입사가 추가로 안 넣으면 정산도 환불도 안 된다 | `test_Limit_ImporterCanStallByNotToppingUp` | 물건을 이미 보낸 수출사가 손해를 본다 |
| 지난 랩의 회로차단기가 전송을 멈추면 에스크로도 멈춘다 | `test_Limit_BreakerPauseFreezesEscrow` | 에스크로 안의 금은 차단기와 상관없는데도 묶인다 |
| 거절은 여전히 수입사 결재선만 할 수 있다 | (테스트 없음) | 진짜 물건을 받고도 2명이 거절하면 환불된다. 분쟁은 체인 밖으로 넘어간다 |
| 서류가 진짜인지는 확인하지 않는다 | (테스트 없음) | `docHash` 는 "이 파일" 을 가리킬 뿐이다. 결재선이 14일 동안 안 보면 가짜 서류로도 정산된다 |
| 시세는 관리자 한 명이 넣는다 | (테스트 없음) | 지난 랩의 보유고 증명처럼 여러 노드 서명으로 바꿀 수 있지만 이번엔 하지 않았다 |

## 남은 질문

- 14일 검토 기간과 110% 여유분은 근거 없이 정했다. 실제 신용장(L/C) 거래에서 서류 심사에 며칠을 주는지, 금 담보 대출의 담보 인정 비율은 얼마인지 찾아보고 다시 정해야 한다.
- 수입사가 추가 담보를 안 넣을 때, 기한을 정해서 그 뒤엔 잠긴 만큼이라도 수출사에게 주는 게 맞을까? 그러면 부족분은 체인 밖 채권이 된다.
- 회로차단기가 걸렸을 때 에스크로의 환불만큼은 허용해야 할까? 지난 랩에서는 "소각은 막지 않는다" 로 정했는데, 에스크로 환불은 소각이 아니라 전송이라 같은 규칙이 적용되지 않았다.
- 거절 사유를 해시로만 남겼는데, 동결 ZK 랩처럼 "승인된 사유 목록 안에 있다" 를 증명하게 하면 수입사가 아무 사유로나 거절하는 걸 줄일 수 있을까?
