"""Settings for the app. Real values come from the .env file."""
import os
from dotenv import load_dotenv

load_dotenv()


class Config:
    SECRET_KEY = os.getenv("SECRET_KEY", "change-this-secret-key")

    DB = {
        "host": os.getenv("DB_HOST", "localhost"),
        "port": int(os.getenv("DB_PORT", "3306")),
        "user": os.getenv("DB_USER", "root"),
        "password": os.getenv("DB_PASSWORD", ""),
        "database": os.getenv("DB_NAME", "api_watch"),
    }

    # Background checker: checks the URLs automatically
    CHECKER_ENABLED = os.getenv("CHECKER_ENABLED", "true").lower() == "true"
    CHECKER_LOOP_SECONDS = int(os.getenv("CHECKER_LOOP_SECONDS", "20"))
    REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "10"))
