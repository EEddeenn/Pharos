# BDS signals

Pharos generates six BDS signals. Each has a primary code per PRN and a
data component. B1C and B2a add a pilot. This page gives the codes, the
power split, the secondary codes and the phase relations. It ends with
the observation codes, the group delays and the PRN allocation.

## The six signals

| | B1I | B2I | B3I | B1C | B2a | B2b |
|---|---|---|---|---|---|---|
| Carrier (MHz) | 1561.098 | 1207.14 | 1268.52 | 1575.42 | 1176.45 | 1207.14 |
| Primary code | Gold, 2046 chips | the B1I code | Gold, 10230 chips | Weil, 10230 chips | Gold, 10230 chips | Gold, 10230 chips |
| Chip rate (Mcps) | 2.046 | 2.046 | 10.23 | 1.023 | 10.23 | 10.23 |
| Code period | 1 ms | 1 ms | 1 ms | 10 ms | 1 ms | 1 ms |
| Components | data | data | data | data, pilot | data, pilot | data (I) |
| Subcarrier | none | none | none | data BOC(1,1), pilot QMBOC(6,1,4/33) | none | none |
| Power | data alone | data alone | data alone | data 1/4, pilot 3/4 | data 1/2, pilot 1/2 | data alone, at half power |
| Secondary code | NH20 on D1 | NH20 on D1 | NH20 on D1 | pilot: 1800 chips | data: 5 chips; pilot: 100 chips | none |
| Symbol | D1 20 ms, D2 2 ms | as B1I | as B1I | 10 ms | 5 ms | 1 ms |
| Message | D1, D2 | D1, D2 | D1, D2 | [B-CNAV1](b-cnav1.md) | [B-CNAV2](b-cnav2.md) | [B-CNAV3](b-cnav3.md), [PPP-B2b](ppp-b2b.md) |
| ICD | B1I 3.0 4.2, Table 4-2 | 2.1 section 4 | B3I 1.0 4.2, Table 4-3 | B1C 1.0 4.2.2, Table 4-2 | B2a 1.0 4.2.2, Table 4-2 | B2b 1.0 4.2.2, equation 4-1 |

D1 runs at 50 bps and D2 at 500 bps ([D1 and D2](d1-d2.md)). The GEO
satellites, PRN 1-5 and 59-63, send D2 on B1I, B2I and B3I.

## Codes

| Code | Generator | ICD |
|---|---|---|
| B1I, B2I | two 11-stage registers, the G2 phase taps of the PRN, 2046 chips | B1I 3.0 4.2, Table 4-2 |
| B3I | two 13-stage registers, G1 reset after 8190 chips, the G2 start state of the PRN | B3I 1.0 4.2, Table 4-3 |
| B2a data, B2a pilot, B2b | two 13-stage registers, G1 reset after 8190 chips, the G2 start state of the PRN | B2a 1.0 4.2.2, B2b 1.0 4.2.2 |
| B1C data, B1C pilot | Weil codes of the length-10243 Legendre sequence, truncated to 10230 chips | B1C 1.0 4.2.2 |
| B1C pilot secondary | Weil code of the length-3607 Legendre sequence, truncated to 1800 chips, 10 ms per chip | B1C 1.0 4.2.2.3 |
| B2a pilot secondary | Weil code of the length-1021 Legendre sequence, 100 chips, 1 ms per chip | B2a 1.0 4.2.4 |
| B2a data secondary | 00010, 1 ms per chip, one pass per symbol | B2a 1.0 4.2 |
| D1 NH code | 00000100110101001110, 1 ms per chip, one pass per bit | B1I 3.0 5.2 |

B2I uses the B1I code on its own carrier. D2 has no NH code: a D2 bit
spans two code periods.

## Phase relations

The data component of every signal lies on the positive real axis. It
is the phase reference of RINEX 3.04 Table A23. The carrier phase of a
signal follows its data code's delay.

| Signal | Real axis | Imaginary axis |
|---|---|---|
| B1I, B2I, B3I | data, amplitude 1 | nothing |
| B1C | data BOC(1,1), amplitude 1/2; pilot BOC(6,1), amplitude sqrt(1/11) | pilot BOC(1,1), amplitude sqrt(29/44) |
| B2a | data, amplitude sqrt(1/2) | pilot, amplitude sqrt(1/2) |
| B2b | data (I), amplitude sqrt(1/2) | nothing |

The B1C rows are equations 4-9 to 4-11 of the B1C ICD: the pilot keeps
29/33 of its power in BOC(1,1) and 4/33 in BOC(6,1). B2b carries half
the power of a full signal, so its C/N0 is 3.01 dB below the scenario's.
The observation file reports that lower C/N0.

## Observation codes and group delays

Each code flies with the group delay of its signal and component. B3I
is the clock reference and carries none. The selected reference's
terms and eligible donors form one common delay table per binding leg
([data](data.md#record-checks)). Tracking, observations and messages
use this table. An unresolved base delay makes that signal unavailable.
A missing ISC_B1Cd or ISC_B2ad contributes zero to its resolved pilot
delay. When only the delay table changes, code delays still blend over
the 600 s transition; messages carry the current binding's values.

| RINEX code | Signal, component | Group delay | Broadcast in |
|---|---|---|---|
| 2I | B1I | T_GD1 | D1 subframe 1, D2 subframe 1 page 1 |
| 7I | B2I | T_GD2 | D1 subframe 1, D2 subframe 1 page 1 |
| 6I | B3I | none | |
| 1D | B1C data | TGD_B1Cp + ISC_B1Cd | B-CNAV1 subframe 2 |
| 1P | B1C pilot | TGD_B1Cp | B-CNAV1 subframe 2, B-CNAV2 type 30 |
| 5D | B2a data | TGD_B2ap + ISC_B2ad | B-CNAV2 type 30 |
| 5P | B2a pilot | TGD_B2ap | B-CNAV1 subframe 2, B-CNAV2 type 30 |
| 7D | B2b (I) | TGD_B2bI | B-CNAV3 type 30 |

T_GD1 and T_GD2 refer to B3I (B1I 3.0 5.2.4.8). B1C and B2a get one
pseudorange per component and one carrier phase, Doppler and C/N0.
The observation file declares RINEX 3.04, whose Table 9 defines the
codes 1D, 1P, 5D, 5P and 7D.

## PRN allocation

Each PRN carries the signals of the CSNO allocation at the scenario
start ([BDS](README.md#satellites)). The April 2026 restructuring moved
satellites between PRNs. Both PRNs of a move switch at its instant. A
PRN named by two moves switches at the earlier. Every other PRN switches
at 2026-04-21 12:00 UTC.

| Instant (UTC, April 2026) | Move from PRN | To PRN |
|---|---|---|
| 10, 12:00 | 38 | 6 |
| 17, 00:00 | 39 | 7 |
| 17, 06:00 | 40 | 8 |
| 17, 13:00 | 60 | 2 |
| 18, 03:00 | 13 | 9 |
| 18, 07:00 | 61 | 3 |
| 18, 11:00 | 16 | 10 |
| 18, 22:00 | 45 | 39 |
| 19, 04:00 | 50 | 14 |
| 19, 08:00 | 49 | 13 |
| 19, 23:00 | 47 | 11 |
| 20, 04:00 | 44 | 31 |
| 20, 08:00 | 43 | 38 |
| 20, 12:00 | 62 | 1 |
| 20, 23:00 | 46 | 40 |
| 21, 04:00 | 48 | 12 |
| 21, 08:00 | 59 | 4 |

A PRN carries its new set from its switch, whether or not a satellite
flies it yet. It transmits only while it flies a record.

## Limits and messages

| Case | Result |
|---|---|
| a listed signal no PRN carries at the start, such as B2I after the restructuring | `no_effect` on `signals`: `B2I is transmitted by no satellite at the start` |
| a satellite on a signal its allocation does not name | no channel and no observables |
| B2b | generated at half power; C/N0 3.01 dB below the scenario's |
