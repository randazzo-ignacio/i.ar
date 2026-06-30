RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

info() { echo -e "${BLUE}[INF][$(timestamp)]${NC} $1"; }
warn() { echo -e "${YELLOW}[WRN][$(timestamp)]${NC} $1"; }
error() { echo -e "${RED}[ERR][$(timestamp)]${NC} $1"; }
