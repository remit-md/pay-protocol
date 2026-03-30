# pay-protocol

Solidity contracts for pay. 4 contracts: PayRouter, PayTab, PayDirect, PayFee.

## Reference
- Remit contracts: `C:\Users\jj\remit-protocol\src\` (frozen, reference only)
- Dev guide: `C:\Users\jj\payskill\spec\guides\SOLIDITY.md`
- General guide: `C:\Users\jj\payskill\spec\guides\GENERAL.md`
- Project spec: `C:\Users\jj\payskill\spec\CLAUDE.md`

## Quick Rules
- Solidity 0.8.x, Foundry, OpenZeppelin
- **NEVER run forge locally on Windows.** Push to CI. Use `--no-verify` on commits.
- Fund-holding contracts (PayTab, PayDirect) are immutable — no proxy
- PayRouter and PayFee use UUPS proxy
- CEI pattern + ReentrancyGuard on all fund-moving functions
- NatSpec on all public functions
- Custom errors, not require strings
- uint96 for all USDC amounts
- Fuzz tests on all numeric operations
- State machine defined BEFORE writing code (see SOLIDITY.md guide)
- No silent fallbacks in fee/amount calculations
- Provider pays 1% fee (0.75% above $50k/month)
- Agent pays activation fee on tab open: max($0.10, 1% of tab amount)
