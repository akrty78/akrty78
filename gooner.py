import os
import requests
import logging
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes
from dotenv import load_dotenv

# --- CONFIGURATION ---
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")

REPO_OWNER = "nexdroidwx"
REPO_NAME = "HyperOS-Modder"

# Authorization
AUTHORIZED_USERS = [1211414285, 987654321]

# Logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)

# --- HELPERS ---
def is_authorized(user_id):
    return user_id in AUTHORIZED_USERS

# --- COMMANDS ---

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id): return
    
    await update.message.reply_text(
        "**NexDroid Manager**\n"
        "------------------\n"
        "System ready.\n\n"
        "Command:\n"
        "`/mod <url>` : Initialize build process",
        parse_mode="Markdown"
    )

async def mod_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id): return

    # 1. Input Validation
    if not context.args:
        await update.message.reply_text(
            "**Error: Invalid Syntax**\n"
            "Usage: `/mod <url>`", 
            parse_mode="Markdown"
        )
        return
    
    rom_url = context.args[0]
    
    # 2. Initial Feedback
    status_msg = await update.message.reply_text(
        "**Processing Request**\n"
        f"Target: `{rom_url}`\n"
        "Status: Authenticating...",
        parse_mode="Markdown"
    )

    # 3. GitHub API Request
    api_url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/dispatches"
    headers = {
        "Authorization": f"token {GITHUB_TOKEN}",
        "Accept": "application/vnd.github.v3+json"
    }
    payload = {
        "event_type": "build_rom",
        "client_payload": {"rom_url": rom_url}
    }

    try:
        response = requests.post(api_url, json=payload, headers=headers)
        
        if response.status_code == 204:
            await status_msg.edit_text(
                "**Build Queued**\n"
                "------------------\n"
                "The build pipeline has been triggered successfully.\n\n"
                "repo: `HyperOS-Modder`\n"
                "status: `running`\n"
                "estimated time: `15m`\n\n"
                "You will be notified upon completion.",
                parse_mode="Markdown"
            )
        else:
            # Clean Error Reporting
            error_map = {
                404: "Repository not found or insufficient token scope.",
                401: "Invalid or expired GitHub token.",
            }
            reason = error_map.get(response.status_code, "Unknown API Error")
            
            await status_msg.edit_text(
                "**Request Failed**\n"
                "------------------\n"
                f"Code: `{response.status_code}`\n"
                f"Reason: {reason}\n"
                f"Response: `{response.text}`",
                parse_mode="Markdown"
            )
            
    except Exception as e:
        await status_msg.edit_text(
            "**Connection Failure**\n"
            f"`{str(e)}`", 
            parse_mode="Markdown"
        )

# --- ENTRY POINT ---
if __name__ == '__main__':
    print(f">> NexDroid Manager Active: {REPO_OWNER}/{REPO_NAME}")
    
    if not TELEGRAM_TOKEN or not GITHUB_TOKEN:
        print(">> FATAL: Configuration missing in .env file.")
        exit(1)

    app = Application.builder().token(TELEGRAM_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("mod", mod_command))

    app.run_polling()
