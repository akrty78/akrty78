import os
import requests
import logging
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes
from dotenv import load_dotenv

# --- CONFIGURATION ---
# Load .env file (Force load from same directory)
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")

# ✅ UPDATED WITH YOUR DETAILS
REPO_OWNER = "nexdroidwx"
REPO_NAME = "HyperOS-Modder"

# Security: Only YOU can trigger builds
AUTHORIZED_USERS = [1211414285, 987654321] 

# Setup Logging
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
        "🏭 **NexDroid Gooner Factory**\n\n"
        "Ready to cook ROMs.\n"
        "Usage: `/mod <url>`",
        parse_mode="Markdown"
    )

async def mod_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update.effective_user.id): return

    # 1. Validation
    if not context.args:
        await update.message.reply_text("❌ **Usage:** `/mod https://link.com/rom.zip`", parse_mode="Markdown")
        return
    
    rom_url = context.args[0]
    
    # 2. Feedback
    msg = await update.message.reply_text(
        f"⚙️ **Processing Request...**\n"
        f"🔗 Target: `{rom_url}`\n"
        f"📡 Contacting GitHub...",
        parse_mode="Markdown"
    )

    # 3. Trigger GitHub Action via API
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
            await msg.edit_text(
                "✅ **Factory Started!**\n\n"
                "The GitHub Server is now downloading and modding the ROM.\n"
                "⏳ **ETA:** 15-20 Minutes.\n\n"
                "_You will receive a notification here when the download link is ready._",
                parse_mode="Markdown"
            )
        else:
            # Enhanced Error Message
            error_reason = "Unknown"
            if response.status_code == 404:
                error_reason = "Bot cannot see the Repo. Check Token Permissions (Must include 'repo' scope)."
            elif response.status_code == 401:
                error_reason = "Token Invalid or Expired."
                
            await msg.edit_text(
                f"❌ **Factory Rejected Request**\n"
                f"Status: `{response.status_code}`\n"
                f"Reason: `{error_reason}`\n"
                f"Raw: `{response.text}`",
                parse_mode="Markdown"
            )
            
    except Exception as e:
        await msg.edit_text(f"❌ **Connection Error**\n`{str(e)}`", parse_mode="Markdown")

# --- MAIN ---
if __name__ == '__main__':
    print(f"🏭 NexGooner Bot Started for repo: {REPO_OWNER}/{REPO_NAME}")
    
    if not TELEGRAM_TOKEN or not GITHUB_TOKEN:
        print("❌ Error: Missing Tokens in .env file")
        print("Make sure you have a file named '.env' (not .env.txt) with your keys.")
        exit(1)

    app = Application.builder().token(TELEGRAM_TOKEN).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("mod", mod_command))

    app.run_polling()
