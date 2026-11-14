describe("BuildSyncCore", function()	local core = require("Modules.BuildSyncCore")
	local sha1 = require("sha1").sha1

	it("pull: builds deleted on GitHub are removed here only if unchanged here", function()
		local state = { ["poe1/A/gone.xml"] = "b1", ["poe1/A/edited.xml"] = "b2", ["poe1/A/missing.xml"] = "b3", ["poe1/A/keep.xml"] = "k" }
		local locals = { ["A/gone.xml"] = "b1", ["A/edited.xml"] = "mine", ["A/keep.xml"] = "k" }
		local plan = core.planPull({ { path = "poe1/A/keep.xml", sha = "k" } }, function(rel) return locals[rel] end, state, "poe1", "poe1/A/")
		assert.are.equals(1, #plan.removals)
		assert.are.equals("A/gone.xml", plan.removals[1].rel)
		table.sort(plan.forget)
		assert.are.same({ "poe1/A/edited.xml", "poe1/A/missing.xml" }, plan.forget)
	end)

	it("pull: no removals outside the scope or on a truncated listing", function()
		local state = { ["poe1/B/x.xml"] = "b" }
		local plan = core.planPull({ }, function() return "b" end, state, "poe1", "poe1/A/")
		assert.are.equals(0, #plan.removals)
		plan = core.planPull({ }, function() return "b" end, state, "poe1", nil, true)
		assert.are.equals(0, #plan.removals)
	end)

	it("pull: refuses to remove most builds at once", function()
		local state, locals = { }, { }
		for i = 1, 30 do state["poe1/A/b"..i..".xml"] = "s"; locals["A/b"..i..".xml"] = "s" end
		local plan = core.planPull({ { path = "poe1/A/b1.xml", sha = "s" } }, function(rel) return locals[rel] end, state, "poe1", "poe1/A/")
		assert.are.equals(0, #plan.removals)
		assert.are.equals(29, plan.blockedRemovals)
	end)

	it("push: deletes on GitHub what was deleted here, unless changed there", function()
		local state = { ["poe1/A/del.xml"] = "d", ["poe1/A/theirs.xml"] = "t0", ["poe1/A/stay.xml"] = "s", ["poe1/B/other.xml"] = "o" }
		local remote = { ["poe1/A/del.xml"] = "d", ["poe1/A/theirs.xml"] = "t1", ["poe1/A/stay.xml"] = "s", ["poe1/B/other.xml"] = "o" }
		local plan = core.planPush({ ["A/stay.xml"] = "s" }, remote, state, "poe1", "A")
		assert.are.equals(1, #plan.deletes)
		assert.are.equals("poe1/A/del.xml", plan.deletes[1].remotePath)
		assert.are.equals("d", plan.deletes[1].remoteSha)
	end)

	it("push: an empty or moved folder never wipes GitHub", function()
		local state, remote = { }, { }
		for i = 1, 25 do state["poe1/A/b"..i..".xml"] = "s"; remote["poe1/A/b"..i..".xml"] = "s" end
		local plan = core.planPush({ }, remote, state, "poe1", "A")
		assert.are.equals(0, #plan.deletes)
		assert.are.equals(25, plan.blockedDeletes)
		-- a few deletions are fine
		plan = core.planPush({ ["A/b1.xml"] = "s" }, { ["poe1/A/b1.xml"] = "s", ["poe1/A/b2.xml"] = "s" }, { ["poe1/A/b1.xml"] = "s", ["poe1/A/b2.xml"] = "s" }, "poe1", "A")
		assert.are.equals(1, #plan.deletes)
	end)


	it("computes git blob shas", function()
		-- `printf 'hello\n' | git hash-object --stdin`
		assert.are.equals("ce013625030ba8dba906f756967f9e9ca394464a", core.blobSha("hello\n", sha1))
		-- empty blob
		assert.are.equals("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", core.blobSha("", sha1))
	end)

	it("maps between local and remote paths", function()
		assert.are.equals("poe1/PlayerOne/a.xml", core.toRemote("poe1", "PlayerOne/a.xml"))
		assert.are.equals("poe1/PlayerOne/a.xml", core.toRemote("/poe1/", "PlayerOne/a.xml"))
		assert.are.equals("PlayerOne/a.xml", core.toRel("poe1", "poe1/PlayerOne/a.xml"))
		assert.is_nil(core.toRel("poe1", "poe2/PlayerOne/a.xml"))
		assert.is_nil(core.toRel("poe1", "README.md"))
		assert.are.equals("README.md", core.toRel("", "README.md"))
	end)

	it("names conflict copies and skips them", function()
		assert.are.equals("PlayerOne/RF Jugg (GitHub copy).xml", core.copyName("PlayerOne/RF Jugg.xml"))
		assert.are.equals("PlayerOne/notes (GitHub copy)", core.copyName("PlayerOne/notes"))
		assert.is_false(core.isSyncable("PlayerOne/RF Jugg (GitHub copy).xml"))
		assert.is_false(core.isSyncable("PlayerOne/.hidden.xml"))
		assert.is_false(core.isSyncable(".git/config"))
		assert.is_true(core.isSyncable("PlayerOne/active.txt"))
	end)

	it("refuses paths that are unsafe on Windows or not builds", function()
		assert.is_false(core.isSyncable("Friend/a\\..\\..\\evil.xml"))
		assert.is_false(core.isSyncable("Friend/build.xml:stream"))
		assert.is_false(core.isSyncable("Friend/C:/x.xml"))
		assert.is_false(core.isSyncable("Friend/../x.xml"))
		assert.is_false(core.isSyncable("Friend/CON.xml"))
		assert.is_false(core.isSyncable("Friend/nul.txt"))
		assert.is_false(core.isSyncable("Friend/CONIN$.xml"))
		assert.is_false(core.isSyncable("Friend/COM\194\185.xml"))
		assert.is_false(core.isSyncable("Friend/x\226\128\174lmx.txt"))
		assert.is_false(core.isSyncable("Friend/trailing.xml."))
		assert.is_false(core.isSyncable("Friend/run.bat"))
		assert.is_false(core.isSyncable("Friend/run.lnk"))
		assert.is_false(core.isSyncable("Friend/a//b.xml"))
		assert.is_false(core.isSyncable("/abs.xml"))
		assert.is_false(core.isSyncable("a/b/c/d/e/f/g.xml"))
		assert.is_true(core.isSyncable("Friend/3.29/Helmbreaker/Chaos & Poison - Softcore.xml"))
		assert.is_true(core.isSyncable("Friend/CONTROL.xml"))
		local plan = core.planPull({
			{ path = "poe1/F/ok.xml", sha = "a1", size = 1000 },
			{ path = "poe1/F/huge.xml", sha = "a2", size = 50 * 1024 * 1024 },
			{ path = "poe1/F/odd.xml", sha = "../x" },
			{ path = "poe1/F/x\\..\\..\\y.xml", sha = "a3" },
		}, function() return nil end, { }, "poe1")
		assert.are.equals(1, #plan.downloads)
		assert.are.equals("F/ok.xml", plan.downloads[1].rel)
	end)

	it("per-player repos: only that player's folder, only valid repo names", function()
		local entries = {
			{ path = "poe1/Alice/a.xml", sha = "a1" },
			{ path = "poe1/Bob/sneaky.xml", sha = "b1" },
			{ path = "poe1/Alicex/c.xml", sha = "c1" },
			{ path = "README.md", sha = "r1" },
		}
		table.insert(entries, { path = "poe1/alice/lower.xml", sha = "l1" })
		local only = core.playerEntries(entries, "poe1", "Alice")
		assert.are.equals(2, #only)
		assert.are.equals("poe1/Alice/a.xml", only[1].path)
		local repos = core.playerRepos({ "builds-Zed", "poe-builds", "builds-Alice", "builds-", "builds-.git", "access", "BUILDS-Bob" }, "builds-")
		assert.are.equals(3, #repos)
		assert.are.equals("builds-Alice", repos[1].repo)
		assert.are.equals("Alice", repos[1].player)
		assert.are.equals("BUILDS-Bob", repos[2].repo)
		assert.are.equals("builds-Zed", repos[3].repo)
	end)

	it("validates repo settings", function()
		assert.is_true(core.validRepoName("POE-Builds"))
		assert.is_false(core.validRepoName("x/y"))
		assert.is_false(core.validRepoName("x?y"))
		assert.is_true(core.validBranch("main"))
		assert.is_false(core.validBranch("a/../b"))
	end)

	it("validates player folder names", function()
		assert.is_true(core.validPlayer("PlayerOne"))
		assert.is_true(core.validPlayer("Friend_2.b-c"))
		assert.is_false(core.validPlayer(""))
		assert.is_false(core.validPlayer("../x"))
		assert.is_false(core.validPlayer("a/b"))
		assert.is_false(core.validPlayer(".git"))
		assert.is_false(core.validPlayer("com1"))
		assert.is_false(core.validPlayer("name."))
	end)

	it("plans a pull", function()
		local remote = {
			{ path = "poe1/A/same.xml", sha = "s1" },
			{ path = "poe1/A/new.xml", sha = "n1" },
			{ path = "poe1/B/theirs.xml", sha = "t2" },       -- changed remotely, unchanged locally
			{ path = "poe1/A/both.xml", sha = "b2" },         -- changed on both sides
			{ path = "poe2/A/other.xml", sha = "o1" },        -- outside root
			{ path = "README.md", sha = "r1" },               -- outside root
		}
		local locals = { ["A/same.xml"] = "s1", ["B/theirs.xml"] = "t1", ["A/both.xml"] = "b3" }
		local state = { ["poe1/B/theirs.xml"] = "t1", ["poe1/A/both.xml"] = "b1" }
		local plan = core.planPull(remote, function(rel) return locals[rel] end, state, "poe1")
		assert.are.equals(1, plan.upToDate)
		assert.are.equals("s1", plan.newState["poe1/A/same.xml"])
		assert.are.equals(3, #plan.downloads)
		local byRel = { }
		for _, d in ipairs(plan.downloads) do byRel[d.rel] = d end
		assert.are.equals("A/new.xml", byRel["A/new.xml"].target)
		assert.is_false(byRel["A/new.xml"].conflict)
		assert.are.equals("B/theirs.xml", byRel["B/theirs.xml"].target)
		assert.is_false(byRel["B/theirs.xml"].conflict)
		assert.are.equals("A/both (GitHub copy).xml", byRel["A/both.xml"].target)
		assert.is_true(byRel["A/both.xml"].conflict)
	end)

	it("treats a first pull over existing different files as a conflict", function()
		local plan = core.planPull({ { path = "poe1/A/x.xml", sha = "r" } }, function() return "l" end, { }, "poe1")
		assert.is_true(plan.downloads[1].conflict)
	end)

	it("plans a push of the player's own folder only", function()
		local locals = {
			["A/same.xml"] = "s1",
			["A/new.xml"] = "n1",
			["A/edited.xml"] = "e2",
			["A/clash.xml"] = "c3",
			["A/gone.xml"] = "g2",
			["A/x (GitHub copy).xml"] = "cp",
			["B/friend.xml"] = "f9",
		}
		local remote = {
			["poe1/A/same.xml"] = "s1",
			["poe1/A/edited.xml"] = "e1",
			["poe1/A/clash.xml"] = "c2",
			["poe1/B/friend.xml"] = "f1",
		}
		local state = {
			["poe1/A/edited.xml"] = "e1",
			["poe1/A/clash.xml"] = "c1",
			["poe1/A/gone.xml"] = "g1",   -- deleted on GitHub since last sync: re-upload
		}
		local plan = core.planPush(locals, remote, state, "poe1", "A")
		assert.are.equals(1, plan.upToDate)
		local uploads = { }
		for _, u in ipairs(plan.uploads) do uploads[u.rel] = u end
		assert.is_not_nil(uploads["A/new.xml"])
		assert.is_nil(uploads["A/new.xml"].remoteSha)
		assert.are.equals("e1", uploads["A/edited.xml"].remoteSha)
		assert.is_not_nil(uploads["A/gone.xml"])
		assert.is_nil(uploads["A/x (GitHub copy).xml"])
		assert.is_nil(uploads["B/friend.xml"])
		assert.are.equals(3, #plan.uploads)
		assert.are.equals(1, #plan.conflicts)
		assert.are.equals("A/clash.xml", plan.conflicts[1].rel)
	end)

	it("lets a push go through after a conflicting pull", function()
		-- Pull saved a copy and moved the base to the remote sha; local edit should now upload
		local state = { ["poe1/A/x.xml"] = "r2" }
		local plan = core.planPush({ ["A/x.xml"] = "l1" }, { ["poe1/A/x.xml"] = "r2" }, state, "poe1", "A")
		assert.are.equals(1, #plan.uploads)
		assert.are.equals("r2", plan.uploads[1].remoteSha)
	end)

	it("url-encodes repo paths", function()
		assert.are.equals("poe1/A/RF%20Jugg%20%28v2%29.xml", core.encodePath("poe1/A/RF Jugg (v2).xml"))
	end)

	it("pull skips files only changed locally", function()
		local state = { ["poe1/Me/a.xml"] = "base" }
		local plan = core.planPull({ { path = "poe1/Me/a.xml", sha = "base" } }, function() return "edited" end, state, "poe1")
		assert.are.equals(0, #plan.downloads)
		assert.are.equals(1, plan.localAhead)
		plan = core.planPull({ { path = "poe1/Me/a.xml", sha = "theirs" } }, function() return "edited" end, state, "poe1")
		assert.are.equals(1, #plan.downloads)
		assert.is_true(plan.downloads[1].conflict)
	end)
end)
