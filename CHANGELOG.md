# Changelog

## [0.10.0](https://github.com/ocalvo/PwrCortex/compare/v0.9.0...v0.10.0) (2026-04-19)


### Features

* capture session context via Out-Default proxy and ground agents on $global:context ([#31](https://github.com/ocalvo/PwrCortex/issues/31)) ([a343377](https://github.com/ocalvo/PwrCortex/commit/a343377c3e3e5d977097772d8334e265b5dd81f1))

## [0.9.0](https://github.com/ocalvo/PwrCortex/compare/v0.8.0...v0.9.0) (2026-04-16)


### Features

* inject session context into system prompt for natural language references ([#26](https://github.com/ocalvo/PwrCortex/issues/26)) ([2cc5069](https://github.com/ocalvo/PwrCortex/commit/2cc506917dd73ea954476c0feb090383ea448857))

## [0.8.0](https://github.com/ocalvo/PwrCortex/compare/v0.7.0...v0.8.0) (2026-04-16)


### Features

* auto-store results in semantic globals with session history ([#25](https://github.com/ocalvo/PwrCortex/issues/25)) ([7d8642b](https://github.com/ocalvo/PwrCortex/commit/7d8642b40e43a0e019156c1ed0925462af4aa121))
* inject global-scope variables into agent and swarm runspaces ([#23](https://github.com/ocalvo/PwrCortex/issues/23)) ([51df438](https://github.com/ocalvo/PwrCortex/commit/51df4382240bf79c4e3ab617feaec2f75895fa67))

## [0.7.0](https://github.com/ocalvo/PwrCortex/compare/v0.6.0...v0.7.0) (2026-04-16)


### Features

* add think alias, token breakdown, and Push-LLMInput cmdlet ([#21](https://github.com/ocalvo/PwrCortex/issues/21)) ([b153332](https://github.com/ocalvo/PwrCortex/commit/b15333252e4f1dc70cb1f4485aafde09c89c1b6c)), closes [#20](https://github.com/ocalvo/PwrCortex/issues/20)

## [0.6.0](https://github.com/ocalvo/PwrCortex/compare/v0.5.0...v0.6.0) (2026-04-15)


### Features

* add Write-Verbose/Warning/Error instrumentation and aliases ([#18](https://github.com/ocalvo/PwrCortex/issues/18)) ([beb4cf0](https://github.com/ocalvo/PwrCortex/commit/beb4cf06bb28a9e4b93c422b0773bda55a050765))

## [0.5.0](https://github.com/ocalvo/PwrCortex/compare/v0.4.0...v0.5.0) (2026-04-15)


### Features

* expose native objects on .Result property of LLMResponse ([#16](https://github.com/ocalvo/PwrCortex/issues/16)) ([a36d313](https://github.com/ocalvo/PwrCortex/commit/a36d3137918e85c4b873c8aaa8ae3435f665189b))

## [0.4.0](https://github.com/ocalvo/PwrCortex/compare/v0.3.0...v0.4.0) (2026-04-15)


### Features

* dedicated agent runspace with object registry and stream capture ([#13](https://github.com/ocalvo/PwrCortex/issues/13)) ([f522da0](https://github.com/ocalvo/PwrCortex/commit/f522da01dfd0c6309cd443887daa3044b1d56127))

## [0.3.0](https://github.com/ocalvo/PwrCortex/compare/v0.2.1...v0.3.0) (2026-04-15)


### Features

* replace ThreadJob swarm workers with RunspacePool ([#11](https://github.com/ocalvo/PwrCortex/issues/11)) ([b7710d3](https://github.com/ocalvo/PwrCortex/commit/b7710d335f2e661bee9e939ddcaada6cbfed8bd3))

## [0.2.1](https://github.com/ocalvo/PwrCortex/compare/v0.2.0...v0.2.1) (2026-04-15)


### Bug Fixes

* PowerShell 7.6 compatibility for PSMemberSet and null guards ([#9](https://github.com/ocalvo/PwrCortex/issues/9)) ([e43e7c8](https://github.com/ocalvo/PwrCortex/commit/e43e7c82ffb9c16983e942ad000187db6728660e))

## [0.2.0](https://github.com/ocalvo/PwrCortex/compare/v0.1.0...v0.2.0) (2026-04-15)


### Features

* create PwrCortex PowerShell module with CI/CD ([1a46779](https://github.com/ocalvo/PwrCortex/commit/1a46779f391a7969042eb902e80c0afa7cde7a82))


### Bug Fixes

* update release-please token to support PAT for PR creation ([7f36bcb](https://github.com/ocalvo/PwrCortex/commit/7f36bcb4d3a6f1e749179570ab1319b9b50d8859))
