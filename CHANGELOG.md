# Changelog

All notable changes to Scope. Versions follow [Semantic Versioning](https://semver.org);
entries are written by release-please from the conventional commits on `main`.

## [0.6.0](https://github.com/antonisPanos/scope/compare/v0.5.0...v0.6.0) (2026-11-13)


### Features

* **stress:** add guarded disk-image QA and resolve stress findings ([#186](https://github.com/antonisPanos/scope/issues/186)) ([ad66eb4](https://github.com/antonisPanos/scope/commit/ad66eb4b91ac87858ce0dc0a5b53d13c559f86f9))

## [0.5.0](https://github.com/antonisPanos/scope/compare/v0.4.1...v0.5.0) (2026-11-10)


### Features

* **engine:** add optional copy recovery journal ([#183](https://github.com/antonisPanos/scope/issues/183)) ([ad501d8](https://github.com/antonisPanos/scope/commit/ad501d8689995f79a20472d723cf10e0fc7e2b87)), closes [#173](https://github.com/antonisPanos/scope/issues/173)
* **operations:** add internal copy folder merge ([#182](https://github.com/antonisPanos/scope/issues/182)) ([18b8ca2](https://github.com/antonisPanos/scope/commit/18b8ca22dc18430c45e0411796f83fb6103bd322)), closes [#171](https://github.com/antonisPanos/scope/issues/171)
* **operations:** report destination incompatibilities before copying ([#177](https://github.com/antonisPanos/scope/issues/177)) ([2b101d3](https://github.com/antonisPanos/scope/commit/2b101d3329255eb8498ed0342a4afe010045bd07))


### Bug fixes

* **engine:** preserve moves when copy finalization fails ([#181](https://github.com/antonisPanos/scope/issues/181)) ([3ba0dc0](https://github.com/antonisPanos/scope/commit/3ba0dc06125c9b847f872ee896221e48206a5d70)), closes [#168](https://github.com/antonisPanos/scope/issues/168) [#174](https://github.com/antonisPanos/scope/issues/174)
* **operations:** keep changed sources after cross-volume copy ([#178](https://github.com/antonisPanos/scope/issues/178)) ([9f26e0e](https://github.com/antonisPanos/scope/commit/9f26e0e5cf29e8a676669998449fec401bfde41d)), closes [#167](https://github.com/antonisPanos/scope/issues/167) [#174](https://github.com/antonisPanos/scope/issues/174)
* **operations:** report skipped transfer outcomes ([#179](https://github.com/antonisPanos/scope/issues/179)) ([0e76497](https://github.com/antonisPanos/scope/commit/0e764974cfcb1c433405b7776537849fb253e76c)), closes [#169](https://github.com/antonisPanos/scope/issues/169) [#174](https://github.com/antonisPanos/scope/issues/174)
* **operations:** scope conflict decisions by item type ([#176](https://github.com/antonisPanos/scope/issues/176)) ([239706d](https://github.com/antonisPanos/scope/commit/239706d8a7ae09a744b4f026369d67e49e043849))

## [0.4.1](https://github.com/antonisPanos/scope/compare/v0.4.0...v0.4.1) (2026-11-04)


### Bug fixes

* **archives:** apply held sidecars before newer metadata ([#163](https://github.com/antonisPanos/scope/issues/163)) ([23e9da5](https://github.com/antonisPanos/scope/commit/23e9da5ebd7ce934fac1ff93178bb5878e2e1d11))
* **archives:** extract through pinned descriptors and bound metadata ([#154](https://github.com/antonisPanos/scope/issues/154)) ([5e1501b](https://github.com/antonisPanos/scope/commit/5e1501bab7b4aaea304c24a77e09c150153e765e))
* **archives:** set quarantine by descriptor, never by a user path ([#164](https://github.com/antonisPanos/scope/issues/164)) ([bbbe002](https://github.com/antonisPanos/scope/commit/bbbe00211d6666cadb2c99b93c90df7e6eaa71e2))
* **copy:** fit generated names when the extension fills the limit ([#162](https://github.com/antonisPanos/scope/issues/162)) ([5ef4e67](https://github.com/antonisPanos/scope/commit/5ef4e67cbff6b5d5710056d58ae0a92bf7017e1c))
* **copy:** keep long names and refuse items a copy can't reproduce ([#153](https://github.com/antonisPanos/scope/issues/153)) ([3a9deb8](https://github.com/antonisPanos/scope/commit/3a9deb82d7c8d895eeb89f69227d90db3a140fa0))
* **delete:** list every item in the permanent-delete confirmation ([#156](https://github.com/antonisPanos/scope/issues/156)) ([5072569](https://github.com/antonisPanos/scope/commit/5072569523c9320c6c4751636b5fb91068500459))
* **disk-images:** check the image for writable mounts and honor cancel ([#155](https://github.com/antonisPanos/scope/issues/155)) ([3dbce9e](https://github.com/antonisPanos/scope/commit/3dbce9e14c23e7f0e3beeb0f8aac9ce0ff5fcef4))
* **search:** check the search folder off the main thread ([#157](https://github.com/antonisPanos/scope/issues/157)) ([b727e6e](https://github.com/antonisPanos/scope/commit/b727e6ec768115e642125a17b8345f94aac5c8ff))

## [0.4.0](https://github.com/antonisPanos/scope/compare/v0.3.0...v0.4.0) (2026-11-03)


### Features

* **browser:** add a compact horizontal list layout ([#140](https://github.com/antonisPanos/scope/issues/140)) ([78c35b6](https://github.com/antonisPanos/scope/commit/78c35b6daf6aaf7302e89b9b940284c385b3faa3))


### Bug fixes

* **browser:** keep navigation buttons in sync with history ([#139](https://github.com/antonisPanos/scope/issues/139)) ([215b00a](https://github.com/antonisPanos/scope/commit/215b00a32980867caddb29b1aaa687b03e430ce8))

## [0.3.0](https://github.com/antonisPanos/scope/compare/v0.2.0...v0.3.0) (2026-11-03)


### Features

* **browser:** show color tags in every view ([#137](https://github.com/antonisPanos/scope/issues/137)) ([cb028bf](https://github.com/antonisPanos/scope/commit/cb028bf1ee6d857f8e5cad544fc47226ad9b2666))

## [0.2.0](https://github.com/antonisPanos/scope/compare/v0.1.0...v0.2.0) (2026-11-02)


### ⚠ BREAKING CHANGES

* **engine:** lift the sandbox; Scope Dev reads anywhere, writes only in ~/ScopeScratch ([#82](https://github.com/antonisPanos/scope/issues/82))

### Features

* **archives:** read archives in a sandboxed XPC service ([#80](https://github.com/antonisPanos/scope/issues/80)) ([1bcc12e](https://github.com/antonisPanos/scope/commit/1bcc12eaf50354c8cc6b9bd8c6c3a3b03bd871ff))
* **browser:** apply folder changes as row diffs ([#68](https://github.com/antonisPanos/scope/issues/68)) ([38c26d0](https://github.com/antonisPanos/scope/commit/38c26d0184cb1831b6baad3a4743a6f4e6fb4a23))
* **browser:** share each folder's listing between tabs and keep recent ones ([#76](https://github.com/antonisPanos/scope/issues/76)) ([1176d7e](https://github.com/antonisPanos/scope/commit/1176d7eec12771f78608875cb283d38e95c1ec05))
* **browser:** show a folder's items as they are read ([#72](https://github.com/antonisPanos/scope/issues/72)) ([17a79e2](https://github.com/antonisPanos/scope/commit/17a79e21d0de01d47d6708ec6c4ef87746d5646a))
* **browser:** show and select what an operation makes at once ([#74](https://github.com/antonisPanos/scope/issues/74)) ([9471d64](https://github.com/antonisPanos/scope/commit/9471d648e5809da6f86e059a722eed1f513c78e6))
* **edit:** cut files with Cmd+X and the right-click menu ([#54](https://github.com/antonisPanos/scope/issues/54)) ([dc7b3f7](https://github.com/antonisPanos/scope/commit/dc7b3f7509f625418526674c5f1621aa52fa2377))
* **engine:** lift the sandbox; Scope Dev reads anywhere, writes only in ~/ScopeScratch ([#82](https://github.com/antonisPanos/scope/issues/82)) ([c220133](https://github.com/antonisPanos/scope/commit/c2201335ea0959a8d20d56d6359a0c84fa881087))
* **engine:** list folders in batches as they are read ([#67](https://github.com/antonisPanos/scope/issues/67)) ([e031478](https://github.com/antonisPanos/scope/commit/e03147834c56facce6df9f4d8da3ad8929217416))
* **engine:** poll network shares for folder changes ([#70](https://github.com/antonisPanos/scope/issues/70)) ([a01098c](https://github.com/antonisPanos/scope/commit/a01098cd39dbc124aded9c7c35f658157bbbb605))
* **engine:** report which children changed and diff listings ([#65](https://github.com/antonisPanos/scope/issues/65)) ([69d9bab](https://github.com/antonisPanos/scope/commit/69d9bab9f0a51e560eb8369a5473913fb877b236))
* **icons:** switch app icons to Icon Composer .icon assets ([#127](https://github.com/antonisPanos/scope/issues/127)) ([26d0f02](https://github.com/antonisPanos/scope/commit/26d0f020a986ea8a7c33848b641d7ee456654f1d))
* **operations:** add Replace If Older to the conflict question ([#66](https://github.com/antonisPanos/scope/issues/66)) ([b15f985](https://github.com/antonisPanos/scope/commit/b15f985086a5de7420f0b93d1e647e95f2ad1f24))
* **operations:** announce each change operations make ([#71](https://github.com/antonisPanos/scope/issues/71)) ([66ca30d](https://github.com/antonisPanos/scope/commit/66ca30ddefc04dbe7b0dee56146267c3d6aa5106))
* **operations:** ask before deleting on a disk with no Trash ([#63](https://github.com/antonisPanos/scope/issues/63)) ([4634fae](https://github.com/antonisPanos/scope/commit/4634faedb9967202f495bc2538850b8d02d9bc63))
* **operations:** ask before undo trashes a file edited since ([#64](https://github.com/antonisPanos/scope/issues/64)) ([fd24b5b](https://github.com/antonisPanos/scope/commit/fd24b5b1d96e07bfe82f412107ec7971ff66a885))
* **operations:** check free space and destination limits before a copy ([#61](https://github.com/antonisPanos/scope/issues/61)) ([735baca](https://github.com/antonisPanos/scope/commit/735bacadb54b2deed5aab3d071945566bb8ae7a9))
* **operations:** offer Try Again, Skip or Stop when an item fails ([#69](https://github.com/antonisPanos/scope/issues/69)) ([2145990](https://github.com/antonisPanos/scope/commit/2145990084e333bb2dd55219321b21ce1b989a23))


### Bug fixes

* accept only plain snapshot names in the dev hooks ([#59](https://github.com/antonisPanos/scope/issues/59)) ([0c0c7c3](https://github.com/antonisPanos/scope/commit/0c0c7c32ae285baadb4ef61eceac7c3813530b8d))
* **archives:** cancel preflight and synchronous XPC waits ([#117](https://github.com/antonisPanos/scope/issues/117)) ([3d45392](https://github.com/antonisPanos/scope/commit/3d45392cee7081f953cbf085ac2ff1e3bf755465))
* **archives:** check space before extracting and stop before the disk fills ([#35](https://github.com/antonisPanos/scope/issues/35)) ([95d0393](https://github.com/antonisPanos/scope/commit/95d039373d60562b44576560e4c8f17fcada17ad))
* **archives:** isolate compression in the sandboxed XPC service ([#124](https://github.com/antonisPanos/scope/issues/124)) ([665b5dc](https://github.com/antonisPanos/scope/commit/665b5dcc7f4de5052cb9b6c8a90310f3c702cc42))
* **archives:** preserve macOS metadata with bounded AppleDouble records ([#122](https://github.com/antonisPanos/scope/issues/122)) ([9bb1c1d](https://github.com/antonisPanos/scope/commit/9bb1c1dac45e39bd8d12bfaf88604f4262f2dad6))
* **archives:** quarantine extracted files before publication ([#107](https://github.com/antonisPanos/scope/issues/107)) ([e0049d5](https://github.com/antonisPanos/scope/commit/e0049d5aae38cf26f3b3098f9ff4a09b6d9355f9))
* **archives:** refuse overflowing unpacked size declarations ([#105](https://github.com/antonisPanos/scope/issues/105)) ([544493f](https://github.com/antonisPanos/scope/commit/544493f276d8746952e6ac5fc8c76a2659b0f3f9))
* **browser:** discard superseded background sort results ([#114](https://github.com/antonisPanos/scope/issues/114)) ([21d5291](https://github.com/antonisPanos/scope/commit/21d529150d5b9220375dbaee7696617cd526cc6f))
* **browser:** keep drops and Open With off the main thread ([#55](https://github.com/antonisPanos/scope/issues/55)) ([c958ee8](https://github.com/antonisPanos/scope/commit/c958ee812e6b128b75e12d189d8bcec56296155a))
* **browser:** keep expanded and column folders live ([#119](https://github.com/antonisPanos/scope/issues/119)) ([c37d24b](https://github.com/antonisPanos/scope/commit/c37d24b1fc2b0da36580ae2cee20b68137ef14a6))
* **browser:** keep symlink objects in incremental listings ([#109](https://github.com/antonisPanos/scope/issues/109)) ([03ea10f](https://github.com/antonisPanos/scope/commit/03ea10fe660df485628d28d4917cdb16b3d966bb))
* **browser:** move read validation and watcher setup off main ([#120](https://github.com/antonisPanos/scope/issues/120)) ([9ec440c](https://github.com/antonisPanos/scope/commit/9ec440c4a9b90bf4989c26610ddfe16ab8a2ccb8))
* **browser:** refresh tags and previews after metadata changes ([#116](https://github.com/antonisPanos/scope/issues/116)) ([cecc700](https://github.com/antonisPanos/scope/commit/cecc70072831f995c12f1a74901658dd1eac7147))
* drop onto folders, live selection highlight, and Print ([#53](https://github.com/antonisPanos/scope/issues/53)) ([337f240](https://github.com/antonisPanos/scope/commit/337f2408f2471245b60cd67d37e5fe98dcbe3b22))
* **engine:** apply file ACLs after the copy so a cancel can clean up ([#33](https://github.com/antonisPanos/scope/issues/33)) ([cb85655](https://github.com/antonisPanos/scope/commit/cb8565553403f290eea5613784aadc85cf858e6a))
* **engine:** clone files on APFS and keep sparse files sparse ([#51](https://github.com/antonisPanos/scope/issues/51)) ([22b12fe](https://github.com/antonisPanos/scope/commit/22b12fee11bba058098ef4c7e9d393b665ba1d26))
* **engine:** copy compressed files with their contents, not zeros ([#83](https://github.com/antonisPanos/scope/issues/83)) ([c70ecc5](https://github.com/antonisPanos/scope/commit/c70ecc542a36e86be66a45d167922de02de16e44))
* **engine:** copy, move and rename on FAT and exFAT disks ([#73](https://github.com/antonisPanos/scope/issues/73)) ([98d6aed](https://github.com/antonisPanos/scope/commit/98d6aed594277be7e876d842179af6458261acf7))
* **engine:** keep an undo available when its items are busy ([#29](https://github.com/antonisPanos/scope/issues/29)) ([cfdd9af](https://github.com/antonisPanos/scope/commit/cfdd9af0bee1641f87f1916a3f2be20b029434c5))
* **engine:** keep tag writes on checked file descriptors ([#134](https://github.com/antonisPanos/scope/issues/134)) ([291eac2](https://github.com/antonisPanos/scope/commit/291eac2cb12a269189527792140a4a31953f5ea5))
* **engine:** lock destination folders and other spellings of busy items ([#32](https://github.com/antonisPanos/scope/issues/32)) ([2073ce1](https://github.com/antonisPanos/scope/commit/2073ce1e2832435d27a3548fae81b7f35fa8ef7a))
* **engine:** pin copy traversal to open directory descriptors ([#113](https://github.com/antonisPanos/scope/issues/113)) ([494ccac](https://github.com/antonisPanos/scope/commit/494ccac10b036aaac6b674c4705f9819861bb3c5))
* **engine:** refuse to rename, move or trash folders macOS needs ([#30](https://github.com/antonisPanos/scope/issues/30)) ([4da2e35](https://github.com/antonisPanos/scope/commit/4da2e35fd4a24e1fe70aa50664a4b01563228621))
* **engine:** run blocking file work on threads of its own ([#36](https://github.com/antonisPanos/scope/issues/36)) ([8dad175](https://github.com/antonisPanos/scope/commit/8dad1751062fc7caa2c61a3721434eedab2339af))
* **engine:** sync folders after copies and fix small resource gaps ([#60](https://github.com/antonisPanos/scope/issues/60)) ([9a4ec70](https://github.com/antonisPanos/scope/commit/9a4ec70b946540c7e503d9d618e4cc5ffe1ba327))
* **engine:** trash a replaced item only once its replacement is ready ([#28](https://github.com/antonisPanos/scope/issues/28)) ([bcf60db](https://github.com/antonisPanos/scope/commit/bcf60db72cea56282e16e18605eb8314d51b6ee1))
* **engine:** validate confirmed permanent deletion identities ([#135](https://github.com/antonisPanos/scope/issues/135)) ([d0e4e08](https://github.com/antonisPanos/scope/commit/d0e4e084502e357ff50edf48482e0780258efddb))
* keep Details columns on screen, readable dark tab pills, clearer pattern label ([#10](https://github.com/antonisPanos/scope/issues/10)) ([6331a1d](https://github.com/antonisPanos/scope/commit/6331a1de82879e6694b9f9a16aab13c06cd22eb7))
* **operations:** check all selected items before toggling tags ([#133](https://github.com/antonisPanos/scope/issues/133)) ([4e87ff0](https://github.com/antonisPanos/scope/commit/4e87ff0b750e5819af1143852b052d64647dd909))
* **operations:** preserve remaining undo steps after failure ([#112](https://github.com/antonisPanos/scope/issues/112)) ([d9893cc](https://github.com/antonisPanos/scope/commit/d9893cc8d78de8747747298cf11788a566475c0c))
* **operations:** say when an operation fails while Scope is in front ([#81](https://github.com/antonisPanos/scope/issues/81)) ([3e5488b](https://github.com/antonisPanos/scope/commit/3e5488bb6269f784bb143e057daa6c3ce55e4509))
* **operations:** undo a trash in Scope Dev; test hooks for cancel and typing ([#84](https://github.com/antonisPanos/scope/issues/84)) ([4a0979a](https://github.com/antonisPanos/scope/commit/4a0979a2eb05b80d7e3138af66f14b49e267a97f))
* **operations:** validate undo object identity and descendants ([#118](https://github.com/antonisPanos/scope/issues/118)) ([5f3ed8b](https://github.com/antonisPanos/scope/commit/5f3ed8b43b4234878343f70b3d64662c51b80b90))
* **preview:** cancel Get Info counting when closed ([#111](https://github.com/antonisPanos/scope/issues/111)) ([1b5513e](https://github.com/antonisPanos/scope/commit/1b5513e0014520ce3385cc5bd026871e4ba33404))
* **preview:** cancel only a closed view's thumbnails and retry failures ([#39](https://github.com/antonisPanos/scope/issues/39)) ([3e357be](https://github.com/antonisPanos/scope/commit/3e357be8032672da0dedd3a8441ff91e8c9a903b))
* **preview:** keep the old thumbnail while a zoom loads the new size ([#57](https://github.com/antonisPanos/scope/issues/57)) ([7acbb4e](https://github.com/antonisPanos/scope/commit/7acbb4ef91ab28225a456bf006380317e1ad1f82))
* **preview:** refresh details independently of quick look ([#132](https://github.com/antonisPanos/scope/issues/132)) ([4c80123](https://github.com/antonisPanos/scope/commit/4c801238f215b66455c8a2e2b6184db3d2ac464e))
* **release:** enable full file operations in production builds ([#125](https://github.com/antonisPanos/scope/issues/125)) ([8841582](https://github.com/antonisPanos/scope/commit/884158281767c024b31f7c95d4adcd996598b1c9))
* **release:** reject debugger entitlements in distribution builds ([#106](https://github.com/antonisPanos/scope/issues/106)) ([a8d2442](https://github.com/antonisPanos/scope/commit/a8d24425d54a9f06046c6d084e5f88cd6e8372e7))
* **search:** clear crawler state when navigation changes ([#110](https://github.com/antonisPanos/scope/issues/110)) ([86e0cf7](https://github.com/antonisPanos/scope/commit/86e0cf7fb14ec3489d04bb124a11329e5c09d92e))
* **search:** publish all Spotlight search and tag results ([#115](https://github.com/antonisPanos/scope/issues/115)) ([18dc3ce](https://github.com/antonisPanos/scope/commit/18dc3ce849d85d8d2d5f13968dba627dc6800b01))
* **search:** stay on one disk and stop after 10,000 results ([#34](https://github.com/antonisPanos/scope/issues/34)) ([ab17782](https://github.com/antonisPanos/scope/commit/ab177821e35ad18e72cb603e5a33a1a4699ed4f7))
* sidebar highlight, delete immediately, tags and details panel selection ([#126](https://github.com/antonisPanos/scope/issues/126)) ([b063b61](https://github.com/antonisPanos/scope/commit/b063b61b5044d7ecd3ce5076e9dc1e2b19c77875))
* **sidebar:** keep the eject spinner until the disk is gone ([#56](https://github.com/antonisPanos/scope/issues/56)) ([58d88f7](https://github.com/antonisPanos/scope/commit/58d88f74f5ff5ff682c2645a11500a685c374c70))
* **tests:** run AnnouncedChangesTests on the main actor ([#79](https://github.com/antonisPanos/scope/issues/79)) ([abe2a0f](https://github.com/antonisPanos/scope/commit/abe2a0f790fcf28e9eddccf02f778ca313b0f2f3))
* **volumes:** force eject only the chosen volume ([#38](https://github.com/antonisPanos/scope/issues/38)) ([8cfbb42](https://github.com/antonisPanos/scope/commit/8cfbb422e554fe0095a85a3c97fadec4284720ef))


### Performance

* **operations:** generate conflict names only when needed ([#108](https://github.com/antonisPanos/scope/issues/108)) ([0ca8d77](https://github.com/antonisPanos/scope/commit/0ca8d77273dabdeebbbda3571a494daec08f1aca))

## 0.1.0 (2026-11-01)

The MVP, milestones M0 to M4.

### Features

* **engine:** file engine with a path guard; development builds reach only the test disks, the release build is read-only
* **browser:** tabs, path bar, sidebar with favourites, recents, tags and volumes, Finder's keyboard shortcuts, Cmd+K command palette
* **browser:** five views (Icons, Details, Columns, Gallery, List), a resizable icon grid with Quick Look thumbnails, and a preview pane
* **operations:** copy, move, duplicate, rename, new folder, move to Trash, compress, extract, mount and eject disk images, with undo
* **operations:** activity drawer with progress, speed, pause, cancel and a reorderable queue; verified moves between disks
* **browser:** split view with tabs on each side and copy or move to the other side
* **search:** search the folder and its subfolders by name, pattern or regular expression, with filters, plus Spotlight content search
