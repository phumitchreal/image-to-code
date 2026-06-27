#!/usr/bin/env node
/**
 * Post-install script for image-to-code.
 * Registers as a skill for opencode and prints setup info for other agents.
 */
const fs = require("fs");
const path = require("path");
const os = require("os");

const PKG_DIR = path.resolve(__dirname, "..");
const SKILL_NAME = "image-to-code";

const OPECODE_SKILL_DIR = path.join(os.homedir(), ".opencode", "skills", SKILL_NAME);

function copyIfNewer(src, dest) {
  try {
    if (fs.existsSync(dest) && fs.statSync(src).mtime <= fs.statSync(dest).mtime) {
      return false; // already up to date
    }
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(src, dest);
    return true;
  } catch (e) {
    console.error(`  ⚠ Could not copy ${src} → ${dest}: ${e.message}`);
    return false;
  }
}

function installOpencodeSkill() {
  console.log(`\n  → Installing ${SKILL_NAME} skill for opencode...`);
  const copied = [];

  const files = ["SKILL.md", "opencode.json"];
  for (const f of files) {
    const src = path.join(PKG_DIR, f);
    const dest = path.join(OPECODE_SKILL_DIR, f);
    if (fs.existsSync(src) && copyIfNewer(src, dest)) {
      copied.push(f);
    }
  }

  if (copied.length > 0) {
    console.log(`  ✓ Copied to ${OPECODE_SKILL_DIR}`);
  } else {
    console.log(`  ✓ Already up to date at ${OPECODE_SKILL_DIR}`);
  }
}

function checkTesseract() {
  try {
    require("child_process").execSync("tesseract --version 2>&1", {
      stdio: "pipe",
      timeout: 5000,
    });
    return true;
  } catch {
    return false;
  }
}

function printInstructions() {
  console.log("");
  console.log("  ┌─────────────────────────────────────────────────────────────┐");
  console.log("  │  image-to-code — AI Agent Skill                            │");
  console.log("  │                                                             │");
  console.log("  │  Installed! Use:                                            │");
  console.log("  │    image-to-code <file>       Full analysis                 │");
  console.log("  │    image-to-code <file> --json Machine-readable JSON        │");
  console.log("  │    image-to-code --clipboard  From clipboard                │");
  console.log("  │                                                             │");
  console.log("  │  For Claude Code CLI, add to ~/.claude/CLAUDE.md:           │");
  console.log("  │    Image analysis: npx image-to-code <file>                 │");
  console.log("  │                                                             │");
  console.log("  │  For Cursor, create .cursorrules with:                      │");
  console.log("  │    Image analysis: npx image-to-code <file> [--json|--full] │");
  console.log("  │                                                             │");
  console.log("  │  For Windsurf, create .windsurfrules with:                  │");
  console.log("  │    Image analysis: npx image-to-code <file> [--json|--full] │");
  console.log("  └─────────────────────────────────────────────────────────────┘");

  if (!checkTesseract()) {
    console.log("");
    console.log("  ⚠ Tesseract OCR not found on PATH.");
    console.log("    Install it:");
    console.log("      macOS:    brew install tesseract tesseract-lang");
    console.log("      Linux:    sudo apt install tesseract-ocr tesseract-ocr-tha");
    console.log("      Windows:  winget install -e --id UB-Mannheim.TesseractOCR");
    console.log("    Thai traineddata will auto-download on first OCR use.");
  }
}

function main() {
  installOpencodeSkill();
  printInstructions();
}

main();
