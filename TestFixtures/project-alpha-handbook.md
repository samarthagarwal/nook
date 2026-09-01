# Project Alpha Handbook

This handbook consolidates engineering, product, and operational notes for Project Alpha — the v1 customer authentication and analytics platform scheduled for Q3 launch. It supplements the formal specification and risk register with day-to-day decisions, open questions, and historical context from prior quarters.

Last updated: September 2026. Owner: Platform Engineering.

---

## Executive summary

Project Alpha delivers a unified login experience for all customer-facing applications, backed by Okta Cloud as the primary identity provider. The analytics layer will ingest authentication events and funnel metrics into the internal data warehouse. The program is funded through FY26 and has executive sponsorship from the VP of Product.

The three largest program risks remain: unestimated analytics scope, single-vendor identity dependency, and recurring vendor delivery slips that compress integration testing windows. Mitigation plans exist on paper but several action items lack named owners.

Launch criteria require successful penetration testing, SOC 2 control evidence for the auth path, and a signed vendor attestation for middleware deliverables. Beta customers are lined up in the financial services and healthcare verticals.

---

## Authentication architecture

The specification names one primary identity provider (Okta Cloud) for all customer authentication flows. No secondary fallback provider is currently configured or provisioned for v1 launch. Review happens before submission in the spec workflow, not after.

Session tokens are short-lived JWTs signed with RS256. Refresh tokens rotate on every use and are stored in HttpOnly cookies on the web clients. Mobile clients use the platform secure enclave via the native SDK wrapper developed in Sprint 14.

Multi-factor authentication is mandatory for admin roles and optional for standard users in v1. Hardware key support (WebAuthn) is scoped for v1.1; the security team accepted this deferral after reviewing threat models for the target customer segments.

Social login (Google, Apple) is out of scope for v1 but the OIDC abstraction layer was designed to allow addition without rewriting the session middleware. The team should avoid hard-coding Okta-specific claim names in business logic — use the internal `IdentityProfile` mapper instead.

Password reset flows must complete in under ninety seconds p95. The UX team validated wireframes in July; engineering estimates two sprints including email template localization for EN, DE, and FR markets.

---

## Identity provider dependency

Risk item #7 in the formal register: single identity provider dependency with no documented fallback path for v1 launch. If Okta experiences a regional outage, customer login fails entirely. The business accepted this risk for launch but demanded a written runbook before go-live.

Proposed fallback for v1.1 includes a read-only maintenance page and optional break-glass local accounts for enterprise tier customers. Legal is reviewing contractual language for SLA credits tied to authentication availability.

The Okta sandbox tenant is provisioned. Production tenant creation is blocked pending InfoSec review of admin role assignments. Two engineers still have standing admin access from a POC in 2024 — access review must close this before production cutover.

Certificate pinning for mobile is implemented but disabled in debug builds. Release builds enforce pinning against Okta’s current intermediate CA set; operations needs a process to update pins when Okta rotates certificates.

---

## Analytics layer

Risk item #14: Analytics layer scope is unestimated and represents a high uncertainty factor for sprint delivery. Product wants funnel dashboards, cohort retention views, and raw event export for data science. Engineering has only sized the ingestion pipeline, not the visualization tier.

The event schema v0.3 defines `auth.login.success`, `auth.login.failure`, `auth.mfa.challenge`, and `auth.logout` as core events. Each event carries `tenant_id`, `user_id`, `client_id`, and a hashed device fingerprint. PII must not appear in event payloads — use opaque identifiers only.

Ingestion targets one million events per day at launch with headroom to ten million without architectural change. Kafka is the buffer; Snowflake is the warehouse destination. The data platform team owns the connector; Platform Engineering owns the emitter in the auth service.

Dashboard requirements are still arguing over real-time versus daily batch. Real-time adds six weeks minimum because the warehouse team lacks streaming SQL capacity. Product lead prefers daily batch for v1 if it ships on time.

Analytics QA needs synthetic login scripts generating known event sequences. QA automation has a draft Playwright suite but it does not yet assert warehouse row counts — manual verification remains the gate.

Open question: who pays for Snowflake compute overages if marketing runs ad-hoc queries against auth events? Finance has not assigned a cost center.

---

## Vendor contract and delivery

Vendor contract section 4.2 limits liability for delayed deliverables and excludes penalty clauses for slips shorter than ten business days. The integration dependency remains on a single approved vendor for authentication middleware.

The vendor delivers a packaged OAuth bridge and a set of migration utilities for legacy session formats. Current contract SOW lists week six of the program as code-complete for the bridge; history suggests adding two to three weeks of slack.

Timeline risk: Integration milestone assumes vendor delivery in week six, but prior slips of two to three weeks have occurred in Q1 and Q2. Mitigation owner is unassigned for the identity provider fallback workstream.

Vendor technical lead changed in May; knowledge transfer was incomplete. Our team lost a week re-validating endpoint behavior against outdated Postman collections. Insist on versioned API docs bound to each milestone acceptance.

Payment terms are 30% on kickoff, 40% on acceptance of milestone two, 30% on production readiness sign-off. We should not sign milestone two until load tests pass at agreed concurrency — previous programs paid early and lost leverage.

Escalation path: account manager → regional director → executive sponsor call. Last executive call resolved a blocking bug in token refresh within forty-eight hours. Keep this path warm.

---

## Timeline and milestones

Timeline slippage retro notes: Vendor delivery slipped 2.5 weeks in Q2, and 3 weeks in Q1. Schedule buffer must account for vendor delays. Team flagged analytics scope as still unestimated while remaining on the v1 milestone list.

Current master schedule ( optimistic ): Sprint 18 — vendor bridge code complete. Sprint 19–20 — integrated end-to-end testing. Sprint 21 — performance and security hardening. Sprint 22 — beta rollout to three design partners. Sprint 23 — GA readiness review.

The pessimistic schedule adds four weeks across vendor and analytics workstreams. Program management has not published the pessimistic plan to stakeholders — only engineering uses it internally.

Holiday blackout: no production changes between December 20 and January 5. If GA slips past mid-December, executive committee prefers January GA over a rushed December launch.

Critical path items this month: complete Okta production tenant, merge analytics emitter behind feature flag, finish penetration test remediation for two medium findings.

---

## Security and compliance

Penetration test round two found one high issue (session fixation via misconfigured redirect URI on staging) and two medium issues (verbose error messages leaking tenant slugs). High issue is fixed; medium fixes are in code review.

SOC 2 Type II audit sampling includes authentication logs and change management tickets for the auth service repository. Ensure every production deploy links to an approved change ticket — auditors rejected two samples in the dry run.

Data residency: EU customers require event storage in `eu-central-1`. The analytics pipeline must tag events with region at ingestion; cross-region replication is prohibited for EU tenant data.

Secrets management: all Okta client secrets live in HashiCorp Vault. Rotations are quarterly. Last rotation was manual and took four hours — automate with the vault operator pattern planned for Sprint 20.

Bug bounty program launches thirty days after GA. Security comms drafted FAQ for researchers; legal approved safe harbor language.

---

## Integration testing

End-to-end tests cover happy-path login, MFA challenge, failed password lockout, and admin impersonation (disabled in production). Missing scenarios: Okta partial outage simulation, clock skew beyond five minutes, and concurrent session limits.

Load testing target: five thousand logins per minute with p99 latency under three hundred milliseconds for token issuance. Last run hit four thousand per minute before CPU saturation on the auth pods — horizontal pod autoscaling rules updated.

Staging environment parity gap: staging uses a smaller Okta org with different rate limits. Performance numbers from staging are directional only; pre-GA test must run against production-scale tenant clone.

Test data hygiene: never copy production user emails to staging. Use synthetic `@alpha-test.example` addresses generated by the fixture factory.

---

## Customer beta program

Three design partners committed: Northwind Financial, Helix Health, and a stealth fintech under NDA. Each receives a dedicated sandbox tenant and weekly office hours with product.

Beta success metrics: ninety-five percent login success rate, fewer than five P1 incidents, and positive qualitative feedback on MFA friction from at least two partners.

Beta feedback channel is a private Slack connect; support rotation is one engineer per week from Platform Engineering. Document recurring questions in this handbook to reduce duplicate answers.

---

## Open decisions log

| ID | Topic | Status | Decision owner |
|----|-------|--------|----------------|
| D-041 | Analytics real-time vs batch | Open | Product |
| D-042 | Break-glass fallback for auth outage | Open | Security + Legal |
| D-043 | Snowflake cost center for ad-hoc queries | Open | Finance |
| D-044 | WebAuthn in v1 vs v1.1 | Closed — v1.1 | Security |
| D-045 | Vendor milestone two payment gate | Open | Program Mgmt |

Decisions marked open block downstream sizing. Escalate D-041 and D-042 in the next steering committee.

---

## Glossary

**IdentityProfile** — Internal DTO mapping OIDC claims to application user fields.

**Emitter** — Lightweight library that publishes analytics events from the auth service.

**Bridge** — Vendor middleware translating legacy session cookies to OIDC tokens.

**Design partner** — Beta customer with contractual feedback obligations.

**GA** — General availability; production launch to all eligible customers.

---

## Appendix: retro action items

From the Q2 timeline retro: (1) Assign mitigation owners before risks enter the register — still incomplete for item #7. (2) Add vendor slack to all external milestones — adopted in pessimistic schedule only. (3) Size analytics visualization separately from ingestion — not done. (4) Maintain a single handbook like this document instead of scattered Notion pages — in progress with this file.

From the Q1 integration retro: vendor API documentation must be a deliverable in every SOW; staging/production parity checklist required before performance sign-off; feature flags mandatory for analytics emitter until warehouse validation passes.

---

*End of handbook. Import this file into the Project Alpha knowledge collection to test multi-section retrieval, citation labels, and hybrid search across authentication, analytics, vendor, and timeline topics.*
