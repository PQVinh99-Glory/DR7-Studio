import io
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import unittest
import zipfile

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "preview"))
import server as preview_server  # noqa: E402


class GovernanceAndPreviewTests(unittest.TestCase):
    def test_single_agents_md_and_dual_cli_compatibility(self) -> None:
        agent_md = REPO_ROOT / "agent.md"
        agents_md = REPO_ROOT / "AGENTS.md"
        dot_agents = REPO_ROOT / ".agents"
        dot_agent = REPO_ROOT / ".agent"

        self.assertFalse(agent_md.exists() or agent_md.is_symlink(), "Redundant agent.md must be removed")
        self.assertTrue(agents_md.is_file(), "Single canonical AGENTS.md must exist for AGY CLI & OpenAI Codex")
        self.assertFalse(agents_md.is_symlink(), "AGENTS.md must be a standalone file, not a dangling symlink")
        self.assertLessEqual(agents_md.stat().st_size, 24000, "Must fit AGY CLI 24KB inline rule limit")

        text = agents_md.read_text(encoding="utf-8")
        for keyword in (
            "Supabase",
            "Godot",
            "Rust",
            "GDExtension",
            "Combined 1-Layer",
            "2,000",
            "60 FPS",
            "state.json",
            "skills.md",
            "lerning.md",
            "loop.sh",
            "Human Test",
            "diagonal_body_sheen",
            "drop_physics",
            "pickup_physics",
        ):
            self.assertIn(keyword, text)

        self.assertTrue(dot_agents.is_dir())
        self.assertTrue(dot_agent.exists())
        self.assertEqual(dot_agent.resolve(), dot_agents.resolve(), ".agent must alias .agents")

        expected_skills = {
            "codeart2d",
            "generate2dmap",
            "generate2dmedia",
            "generate2dsprite",
            "video2dsprite",
            "dr7-governance",
        }
        for sk in expected_skills:
            self.assertTrue((dot_agents / "skills" / sk / "SKILL.md").is_file(), f"Missing SKILL.md for {sk}")
            self.assertTrue((dot_agents / "skills" / sk / "agents" / "openai.yaml").is_file(), f"Missing openai.yaml for {sk}")

    def test_old_test_characters_completely_purged(self) -> None:
        assets_dir = REPO_ROOT / "assets"
        scenes_dir = REPO_ROOT / "scenes"
        tools_dir = REPO_ROOT / "tools"
        for p in list(assets_dir.rglob("*")) + list(scenes_dir.rglob("*")):
            low = p.name.lower()
            self.assertNotIn("songoku", low, f"Old Son Goku test asset must be deleted: {p}")
            self.assertNotIn("sphere_of_destruction", low, f"Old purple test asset must be deleted: {p}")
            self.assertNotIn("modularauracharacter", low, f"Deprecated 3-layer rig script must be deleted: {p}")
            self.assertNotIn("trunks", low, f"Deleted Trunks asset/scene must not remain: {p}")
        self.assertFalse(
            (tools_dir / "pipeline" / "build_trunks_rage.py").exists(),
            "Deleted Trunks extraction script must not remain",
        )

    def test_skills_md_remains_empty_until_owner_approval_and_lerning_md_populated(self) -> None:
        skills_txt = (REPO_ROOT / "skills.md").read_text(encoding="utf-8")
        m_sk = re.search(r"<!-- SKILLS_ENTRIES_START -->(.*?)<!-- SKILLS_ENTRIES_END -->", skills_txt, re.S)
        self.assertIsNotNone(m_sk)
        sk_entries = re.findall(r"^###\s+\[([^]]+)\]", m_sk.group(1), re.M)
        st_data = json.loads((REPO_ROOT / "state.json").read_text())
        workflows = st_data.get("approved_workflows", [])
        item_workflows = st_data.get("approved_item_workflows", [])
        self.assertEqual(
            set(sk_entries),
            {w["id"] for w in workflows} | {w["id"] for w in item_workflows},
            "Every character & item workflow needs recorded Owner acceptance",
        )
        for iw in item_workflows:
            i_receipt = json.loads((REPO_ROOT / iw["approval_file"]).read_text())
            self.assertEqual(i_receipt["status"], "owner_approved")
            self.assertEqual(i_receipt["item_set_id"], iw["item_set_id"])
            self.assertTrue(i_receipt["owner_message"].strip())
            i_atlas = REPO_ROOT / i_receipt["atlas_path"]
            self.assertEqual(hashlib.sha256(i_atlas.read_bytes()).hexdigest(), i_receipt["atlas_sha256"])
        # Verify ritual sequence SHA-256 matches approved ritual receipt when status is owner_approved
        ritual_seq_path = REPO_ROOT / "assets" / "rituals" / "shenron_summon" / "sequence.json"
        if ritual_seq_path.is_file():
            ritual_seq = json.loads(ritual_seq_path.read_text())
            if ritual_seq.get("qa", {}).get("status") == "owner_approved":
                ritual_receipt = json.loads((REPO_ROOT / "assets" / "rituals" / "shenron_summon" / "owner_approval.json").read_text())
                self.assertEqual(ritual_receipt["status"], "owner_approved")
                self.assertEqual(hashlib.sha256(ritual_seq_path.read_bytes()).hexdigest(), ritual_receipt["sequence_sha256"])
        by_id = {w["id"]: w for w in workflows}
        for workflow in workflows:
            receipt = json.loads((REPO_ROOT / workflow["approval_file"]).read_text())
            self.assertEqual(receipt["status"], "owner_approved")
            self.assertEqual(receipt["character_id"], workflow["character_id"])
            self.assertTrue(receipt["owner_message"].strip())
            atlas = REPO_ROOT / "assets" / receipt["character_id"] / "godot_bundle/godot" / (receipt["character_id"] + "-atlas-00.png")
            if workflow.get("archived_atlas_purged") and workflow.get("superseded_by"):
                self.assertEqual(workflow.get("atlas_sha256"), receipt["atlas_sha256"])
                approved_atlas = None
            else:
                approved_atlas = REPO_ROOT / workflow["approved_atlas_path"] if workflow.get("approved_atlas_path") else atlas
                self.assertEqual(hashlib.sha256(approved_atlas.read_bytes()).hexdigest(), receipt["atlas_sha256"])
            if approved_atlas is None or approved_atlas != atlas:
                ch = next(c for c in json.loads((REPO_ROOT / "assets/roster.json").read_text())["characters"]
                          if c["character_id"] == receipt["character_id"])
                review = ch["motion_quality"]
                sup_id = workflow.get("superseded_by")
                if sup_id:
                    seen = {workflow["id"]}
                    cur_id = sup_id
                    while cur_id:
                        self.assertNotIn(cur_id, seen, "Cycle in superseded_by chain")
                        seen.add(cur_id)
                        sup = by_id[cur_id]
                        cur_id = sup.get("superseded_by")
                    sup_receipt = json.loads((REPO_ROOT / sup["approval_file"]).read_text())
                    self.assertEqual(sup["character_id"], receipt["character_id"])
                    self.assertEqual(sup_receipt["status"], "owner_approved")
                    self.assertEqual(sup_receipt["atlas_sha256"], hashlib.sha256(atlas.read_bytes()).hexdigest())
                    if sup.get("approved_atlas_path") or sup.get("archived_atlas_purged"):
                        self.assertEqual(review["status"], "reviewed_pending_owner")
                        self.assertFalse(review["owner_approved"])
                        self.assertEqual(review["previous_revision_atlas_sha256"], sup_receipt["atlas_sha256"])
                    else:
                        self.assertTrue(review["owner_approved"])
                else:
                    # An accepted historical revision must not approve unseen new art.
                    self.assertEqual(review["status"], "reviewed_pending_owner")
                    self.assertEqual(review["atlas_sha256"], hashlib.sha256(atlas.read_bytes()).hexdigest())
                    self.assertFalse(review["owner_approved"])
                    self.assertEqual(review["previous_revision_atlas_sha256"], receipt["atlas_sha256"])

        lerning_txt = (REPO_ROOT / "lerning.md").read_text(encoding="utf-8")
        m_lr = re.search(r"<!-- LERNING_ENTRIES_START -->(.*?)<!-- LERNING_ENTRIES_END -->", lerning_txt, re.S)
        self.assertIsNotNone(m_lr)
        lr_entries = re.findall(r"^###\s+\[(LRN-\d+)\]", m_lr.group(1), re.M)
        all_lr_entries = re.findall(r"^###\s+\[(LRN-\d+)\]", lerning_txt, re.M)
        self.assertGreaterEqual(len(lr_entries), 6, "lerning.md should record verified bug fixes LRN-001..006")
        self.assertEqual(len(lr_entries), len(all_lr_entries), "No LRN entry may lie outside LERNING_ENTRIES_END")
        self.assertEqual(len(all_lr_entries), len(set(all_lr_entries)), "All LRN IDs in lerning.md must be unique")

    def test_version_sync_across_all_manifests(self) -> None:
        ver = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip()
        self.assertRegex(ver, r"^\d+\.\d+\.\d+$")
        state = json.loads((REPO_ROOT / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["project"]["version"], ver)
        pg = (REPO_ROOT / "project.godot").read_text(encoding="utf-8")
        self.assertIn(f'config/version="{ver}"', pg)
        cargo_txt = (REPO_ROOT / "engines" / "rust_combat_sim" / "Cargo.toml").read_text(encoding="utf-8")
        self.assertIn(f'version = "{ver}"', cargo_txt)
        ep_txt = (REPO_ROOT / "export_presets.cfg").read_text(encoding="utf-8")
        self.assertIn(f'version/name="{ver}"', ep_txt)
        self.assertIn(f'application/short_version="{ver}"', ep_txt)

    def test_engine_localhost_zero_drift_parity_and_dynamic_roster(self) -> None:
        parity = preview_server.verify_engine_localhost_parity()
        self.assertTrue(parity["ok"], msg=f"Parity errors: {parity['errors']}")
        roster = preview_server.load_finalized_roster()
        chars = roster.get("characters", [])
        self.assertEqual(parity["finalized_characters"], len(chars))
        self.assertEqual(parity["checked_bundles"], len(chars))

        if not chars:
            self.assertEqual(preview_server.discover_bundles(), [])
            self.assertEqual(preview_server.build_setups([]), [])
            self.assertGreaterEqual(len(parity["warnings"]), 1, "Empty roster should report readiness warning")
        else:
            for ch in chars:
                self.assertNotIn("layered_3d_depth", ch["modes"], "Multi-layer mode (Hướng 2) must be removed")
                self.assertIn("combined_1layer", ch["modes"])
                self.assertEqual(ch["pixel_sharpness_metrics"]["enclosed_key_pockets"], 0)
                self.assertEqual(ch["pixel_sharpness_metrics"]["opaque_key_px"], 0)

    def test_hybrid_engine_benchmark_report_and_wasm_artifact(self) -> None:
        bench_path = REPO_ROOT / "engines" / "benchmark_report.json"
        self.assertTrue(bench_path.is_file())
        bench = json.loads(bench_path.read_text(encoding="utf-8"))
        self.assertIn("shared_asset_under_test", bench)
        self.assertIsNone(bench["shared_asset_under_test"].get("bundle_id"))
        self.assertGreaterEqual(len(bench["rust_engine"]["benchmarks"]), 3)
        self.assertGreaterEqual(len(bench["godot_engine"]["benchmarks"]), 6)
        wasm_path = REPO_ROOT / "tools" / "preview" / "rust_combat_sim.wasm"
        self.assertTrue(wasm_path.is_file())
        self.assertGreater(wasm_path.stat().st_size, 1024)

    def test_loop_sh_check_and_agy_hook(self) -> None:
        res_chk = subprocess.run([str(REPO_ROOT / "loop.sh"), "check"], capture_output=True, text=True, check=False)
        self.assertEqual(res_chk.returncode, 0, msg=res_chk.stderr)

        res_hk = subprocess.run(
            [str(REPO_ROOT / "loop.sh"), "--agy-session-start"],
            input="{}",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res_hk.returncode, 0, msg=res_hk.stderr)
        payload = json.loads(res_hk.stdout)
        self.assertIn("injectSteps", payload)
        self.assertIn("AGENTS.md", payload["injectSteps"][0]["systemMessage"]["systemMessage"])

    def test_preview_server_zip(self) -> None:
        zbytes = preview_server.build_godot_zip_bytes()
        with zipfile.ZipFile(io.BytesIO(zbytes)) as zf:
            names = set(zf.namelist())
            self.assertIn("project.godot", names)
            self.assertIn("export_presets.cfg", names)
            self.assertIn("VERSION", names)
            self.assertIn("assets/roster.json", names)
            self.assertIn("assets/i18n/languages.json", names)
            self.assertIn("scenes/CharacterFighter2D.gd", names)
            self.assertIn("scenes/SkillAnimator2D.gd", names)
            self.assertIn("scenes/runtime/DisplayPolicy.gd", names)
            self.assertIn("scenes/runtime/I18nManager.gd", names)
            self.assertIn("scenes/net/WebSocketTransport.gd", names)
            self.assertIn("assets/maps/rocky_plateau/device-profiles.json", names)
            self.assertFalse(any("/godot-sprite3d/" in n or "/aseprite/" in n or "/source/" in n for n in names),
                             "Godot export ZIP should exclude sprite3d/aseprite/source bloat")
            self.assertNotIn("scenes/Trunks_Rage.tscn", names)

    def test_frontend_js_wasm_exports_2tabs_and_n_character_roster(self) -> None:
        res = subprocess.run(
            ["node", str(REPO_ROOT / "tests" / "test_frontend_wasm_e2e.mjs")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 0, msg=f"Frontend E2E failed:\n{res.stdout}\n{res.stderr}")

    def test_server_auto_godot_web_bootstrap_contract(self) -> None:
        import tempfile

        args_default = preview_server.parse_cli_args([])
        self.assertFalse(args_default.no_auto_godot, "Server must auto-bootstrap Godot Web by default")
        self.assertEqual(args_default.port, 8080)

        with tempfile.TemporaryDirectory() as tmp:
            tdir = pathlib.Path(tmp)
            self.assertFalse(preview_server.is_godot_web_built(tdir))
            for fname in ("index.html", "index.pck", "index.wasm", "index.js"):
                (tdir / fname).write_text("ok", encoding="utf-8")
            self.assertTrue(preview_server.is_godot_web_built(tdir))

        st = preview_server.get_godot_web_bootstrap_status()
        for key in ("state", "godot_version", "godot_installed", "templates_installed", "godot_web_ready"):
            self.assertIn(key, st)

        install_txt = (REPO_ROOT / "tools" / "godot" / "install_godot.sh").read_text(encoding="utf-8")
        self.assertIn("--with-templates", install_txt)
        loop_txt = (REPO_ROOT / "loop.sh").read_text(encoding="utf-8")
        self.assertIn("serve)", loop_txt)
        self.assertIn("build/.gdignore", loop_txt)

    def test_godot_zip_completeness_ios_preset_and_d8_compliance(self) -> None:
        import io
        import zipfile

        zbytes = preview_server.build_godot_zip_bytes()
        with zipfile.ZipFile(io.BytesIO(zbytes)) as zf:
            names = set(zf.namelist())
        for req in (
            "assets/fx/powerup_explosion/powerup_explosion.tres",
            "assets/fx/hit_impact/hit_impact.tres",
            "assets/fx/hit_impact/hit_impact-atlas-00.png",
            "assets/body_silhouettes.json",
            "assets/app_icon/icon_512.png",
            "assets/maps/rocky_plateau/rocky-plateau-extended-4steps.png",
            "assets/maps/rocky_plateau/rocky-plateau-foreground-trees.png",
        ):
            self.assertIn(req, names, f"Godot ZIP missing required runtime asset: {req}")
        self.assertNotIn("image copy 2.png", names)

        html_txt = (REPO_ROOT / "tools" / "preview" / "index.html").read_text(encoding="utf-8")
        self.assertNotIn("GDExtension", html_txt, "index.html must not claim GDExtension (AGENTS.md D8)")

        presets_txt = (REPO_ROOT / "export_presets.cfg").read_text(encoding="utf-8")
        self.assertIn("architectures/arm64-v8a=true", presets_txt)
        self.assertIn("architectures/x86_64=false", presets_txt)
        self.assertIn("progressive_web_app/enabled=true", presets_txt)
        self.assertIn('platform="iOS"', presets_txt)

        self.assertTrue((REPO_ROOT / ".github" / "workflows" / "build-ios-ipa.yml").is_file())
        self.assertTrue((REPO_ROOT / "tools" / "infra" / "install_cloud_clis.sh").is_file())
        self.assertTrue((REPO_ROOT / "tools" / "ios" / "generate_altstore_source.py").is_file())
        self.assertTrue((REPO_ROOT / "tools" / "ios" / "repack_ios_pck.sh").is_file())
        self.assertTrue((REPO_ROOT / "docs" / "ios" / "sideload-and-testflight-setup.md").is_file())

        # Verify locked 5-language i18n pack (default en, settings-only change)
        i18n_cfg = json.loads((REPO_ROOT / "assets" / "i18n" / "languages.json").read_text(encoding="utf-8"))
        self.assertEqual(i18n_cfg["default_locale"], "en")
        self.assertFalse(i18n_cfg["auto_detect_os_locale"])
        self.assertTrue(i18n_cfg["change_only_in_settings"])
        codes = [loc["code"] for loc in i18n_cfg["supported_locales"]]
        self.assertEqual(codes, ["en", "zh-CN", "vi", "es", "pt-BR"])

        # Verify AltStore / SideStore source JSON generator
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            fake_ipa = pathlib.Path(tmp) / "test.ipa"
            fake_ipa.write_bytes(b"PK\x03\x04dr7-test-ipa")
            out_json = pathlib.Path(tmp) / "altstore-source.json"
            res = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "tools" / "ios" / "generate_altstore_source.py"),
                    "--version", "0.16.0",
                    "--ipa", str(fake_ipa),
                    "--download-url", "https://example.com/dr7.ipa",
                    "--output", str(out_json),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            src = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(src["apps"][0]["bundleIdentifier"], "com.dr7studio.dragonball2d")
            self.assertEqual(src["apps"][0]["versions"][0]["size"], fake_ipa.stat().st_size)
            self.assertEqual(src["apps"][0]["appPermissions"]["entitlements"], [])

            # Verify generate_altstore_source.py fails non-zero when --ipa is missing
            res_missing = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "tools" / "ios" / "generate_altstore_source.py"),
                    "--version", "0.16.0",
                    "--ipa", str(pathlib.Path(tmp) / "does-not-exist.ipa"),
                    "--download-url", "https://example.com/dr7.ipa",
                    "--output", str(out_json),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(res_missing.returncode, 0)

            # Verify server get_ios_ipa_info metadata contract
            ipa_meta = preview_server.get_ios_ipa_info(fake_ipa, fake_ipa)
            self.assertTrue(ipa_meta["available"])
            self.assertEqual(ipa_meta["download_url"], "/api/download-ios-unsigned.ipa")
            self.assertEqual(ipa_meta["altstore_source_url"], "/api/ios-altstore-source.json")
            self.assertTrue(ipa_meta["base_ipa_present"])

        # Verify opaque RGB iOS icons match Apple required dimensions (no alpha channel)
        from PIL import Image
        for sz in (76, 120, 152, 167, 180, 1024):
            icon_p = REPO_ROOT / "assets" / "app_icon" / "ios" / f"ios_icon_{sz}.png"
            self.assertTrue(icon_p.is_file(), f"Missing opaque iOS icon: {icon_p}")
            with Image.open(icon_p) as im:
                self.assertEqual(im.mode, "RGB", f"iOS icon {icon_p.name} must be opaque RGB")
                self.assertEqual(im.size, (sz, sz), f"iOS icon {icon_p.name} size mismatch")

        loop_txt2 = (REPO_ROOT / "loop.sh").read_text(encoding="utf-8")
        self.assertIn("build-all)", loop_txt2)
        self.assertIn("ios-repack)", loop_txt2)

        # Verify motion_quality instant_flip exception (Owner 2026-11-14/19: no mandatory turn for new chars)
        from motion_quality import assess_motion_quality, REQUIRED_CHECKS
        flip_review = {
            "status": "reviewed_pending_owner",
            "method": "imagegen_complete_body_keyframes",
            "atlas_sha256": "abc123",
            "checks": {k: (k != "perspective_turns") for k in REQUIRED_CHECKS},
            "not_applicable_checks": {"perspective_turns": "Instant horizontal flip per AGENTS.md 7.4"},
        }
        flip_rc = {"turning": {"method": "instant_flip", "clip": None}}
        self.assertTrue(assess_motion_quality(flip_review, "abc123", flip_rc)["ok_for_human_test"])
        non_flip_rc = {"turning": {"method": "perspective_turn", "clip": "turn"}}
        self.assertFalse(assess_motion_quality(flip_review, "abc123", non_flip_rc)["ok_for_human_test"])

        # Verify /api/ios-altstore-source.json returns absolute URLs dynamically and 404 when IPA missing
        import http.server
        import threading
        import urllib.error
        import urllib.request
        orig_ipa = preview_server.IOS_IPA_PATH
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), preview_server.PreviewHandler)
        port = httpd.server_address[1]
        th = threading.Thread(target=httpd.serve_forever, daemon=True)
        th.start()
        try:
            with tempfile.TemporaryDirectory() as tmp2:
                missing_ipa = pathlib.Path(tmp2) / "missing.ipa"
                preview_server.IOS_IPA_PATH = missing_ipa
                with self.assertRaises(urllib.error.HTTPError) as ctx:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/api/ios-altstore-source.json", timeout=5)
                self.assertEqual(ctx.exception.code, 404)
                ctx.exception.close()

                present_ipa = pathlib.Path(tmp2) / "present.ipa"
                present_ipa.write_bytes(b"PK\x03\x04dr7-altstore-http-test")
                preview_server.IOS_IPA_PATH = present_ipa
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/ios-altstore-source.json", timeout=5) as resp:
                    self.assertEqual(resp.status, 200)
                    alt_doc = json.loads(resp.read().decode("utf-8"))
                dl_url = alt_doc["apps"][0]["versions"][0]["downloadURL"]
                self.assertTrue(dl_url.startswith(f"http://127.0.0.1:{port}/api/download-ios-unsigned.ipa"), dl_url)
        finally:
            preview_server.IOS_IPA_PATH = orig_ipa
            httpd.shutdown()
            httpd.server_close()


if __name__ == "__main__":
    unittest.main()
