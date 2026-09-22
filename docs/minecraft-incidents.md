# Minecraft incident log

This file records only observed evidence, actions, and verification results.
An entity appearing in a stack trace is a trigger-path observation, not a
proven root cause.

## 2026-09-19 — WorldOfSosal crashes in Sable block-change handling

### Impact

- `minecraft-server-wowMineMap.service` terminates while a player is online.
- Public Minecraft endpoint is `store.hectic-lab.com:25568`.
- Server is intentionally stopped after the latest crash to prevent repeated
  crash-save cycles while recovery is investigated.

### Observed evidence

All crash reports contain `sable@2.0.5` in
`LevelAccelerator.getBlockState`, followed by
`ArrayIndexOutOfBoundsException` where the requested section index exceeds
the world section array length of `24`.

| UTC timestamp | Crash report | Observed trigger path | Exception |
| --- | --- | --- | --- |
| 18:47:03 | `crash-2026-09-19_18.47.03-server.txt` | `EnderMan$EndermanTakeBlockGoal.tick` | index `38` / length `24` |
| 18:52:17 | `crash-2026-09-19_18.52.17-server.txt` | `GlowSquid.aiStep` → `RedStoneOreBlock.stepOn` | index `33` / length `24` |
| 19:14:46 | `crash-2026-09-19_19.14.46-server.txt` | `Skeleton.tick` → `RedStoneOreBlock.stepOn` | index `34` / length `24` |

Evidence locations on `neuro`:

```text
/srv/minecraft/wowMineMap/crash-reports/
/srv/minecraft/wowMineMap/logs/latest.log
```

### Actions performed

| UTC timestamp | Action | Result |
| --- | --- | --- |
| 17:51 | Archived current world before recovery | Archive checksum recorded |
| 18:08 | Set `randomTickSpeed=0` | Server started, but later crashed from an entity block change |
| 18:48 | Set `mobGriefing=false` | Prevented Enderman block pickup only; later crashes still occurred |
| 18:54 | Archived post-crash world | Archive checksum recorded |
| 19:00 | Moved Boss offline player NBT from `(3299.067, 142.630, 8613.742)` to `(3296, 500, 8608)` in `crafting_azeroth:azeroth` | Only `Pos` and `Dimension` changed; later crash still occurred |
| after 19:14 crash | Stopped `minecraft-server-wowMineMap.service` | Prevented further automatic crash/restart saves |

### Recovery artifacts

```text
/srv/minecraft/backups/wowMineMap-before-sable-recovery-20260919T175139Z.tar.zst
/srv/minecraft/backups/wowMineMap-after-sable-crashes-20260919T185445Z.tar.zst
/srv/minecraft/wowMineMap/world/playerdata/1c189af5-2713-3fa6-bcc4-893dfadedfa4.dat.before-relocation
```

### Conclusions supported by evidence

- Public proxy and reverse tunnel are not the failure point: server-list ping
  succeeded before later in-world crashes.
- The failure is not limited to Endermen, random ticks, or one player
  position.
- Sable's block-change callback is present in every captured crash.

### Not established

- Exact corrupt chunk, block, or mod data.
- Whether world data is corrupt, Sable itself is defective, or another mod is
  supplying incompatible world state.
- Whether deleting any chunk, region, or Sable state would be safe.

### External research

No exact upstream match was found for Sable `2.0.5` on NeoForge `1.21.1` with
`LevelAccelerator.getBlockState` and a requested section index of `33`, `34`,
or `38` against a section array of length `24`.

Related but non-identical upstream reports:

- [Sable #776](https://github.com/ryanhcode/sable/issues/776) documents an
  `ArrayIndexOutOfBoundsException` associated with unusual dimension height
  bounds. This is relevant to section-coordinate handling, but is an older
  version and different stack trace.
- [Sable #1087](https://github.com/ryanhcode/sable/issues/1087) documents a
  `LevelAccelerator.getBlockState` recursion during block-shape processing.
  The failure type differs.
- [Sable #820](https://github.com/ryanhcode/sable/issues/820) documents a
  ticking-entity block-change crash. The reported downgrade to `1.1.3` helped
  that distinct recursive-update failure; it is not evidence for this crash.
- [Sable #1223](https://github.com/ryanhcode/sable/issues/1223) documents a
  different `ArrayIndexOutOfBoundsException` in voxel-neighborhood handling.
  Its suggested Lithium setting only reduced crashes for some reporters and is
  not a verified mitigation here.

Sable `2.0.4` and `2.0.5` release notes mention other block or contraption
crash fixes, but not this exception. No version upgrade or downgrade is
currently evidence-backed as a production fix.

### Next recovery step

Use a disposable full-world copy to test a supported Sable/physics integration
mitigation. Do not restart production, delete region files, or overwrite a
backup until that test gives reproducible evidence.
