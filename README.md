# pay-protocol

Smart contracts for Pay -- the complete x402 payment stack for AI agents. USDC on Base.

## Contracts

| Contract | Role | Upgradeability |
|----------|------|---------------|
| **PayDirect** | One-shot USDC transfers with fee deduction | Immutable |
| **PayTab** (V2/V5) | Tab lifecycle: open, charge, settle, close, top-up | Immutable |
| **PayFee** | Fee calculation and provider volume tracking | UUPS upgradeable |
| **PayRouter** | Entry point for x402 settlement and direct payments | UUPS upgradeable |

Fund-holding contracts (PayDirect, PayTab) are immutable -- no proxy, no admin key, no upgrade path. USDC flows directly between agent and provider via the contract.

## Security

- Immutable fund-holding contracts (no admin functions)
- CEI pattern + reentrancy guards on all state-changing functions
- `maxChargePerCall` enforced on-chain per tab
- Activation fee prevents dust-tab spam
- Custom errors (no require strings)
- Fuzz tests on all numeric operations
- Invariant tests on safety properties

## Development

This is a Foundry project. Solidity 0.8.x with OpenZeppelin.

```bash
forge build
forge test
```

## Deployed Addresses

Always fetch addresses at runtime from the API:

```bash
curl https://pay-skill.com/api/v1/contracts
```

See [Contracts & Networks](https://pay-skill.com/docs/contracts) for details.

## Part of Pay

Pay is the complete x402 payment stack -- gateway, facilitator, SDKs, CLI, and MCP server -- that lets AI agents pay for APIs with USDC on Base.

- [Documentation](https://pay-skill.com/docs/)
- [Architecture](https://pay-skill.com/docs/architecture)
- [SDK](https://github.com/pay-skill/pay-sdk) -- Python + TypeScript
- [CLI](https://github.com/pay-skill/pay-cli) -- Command-line tool
- [pay-gate](https://github.com/pay-skill/gate) -- x402 payment gateway
- [MCP Server](https://github.com/pay-skill/mcp) -- Claude Desktop / Cursor / VS Code

## License

MIT
