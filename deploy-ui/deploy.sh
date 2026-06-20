#!/bin/bash
set -e

# ─── Config ───────────────────────────────────────────────────────────────────
ACR_NAME="${AZURE_ACR_NAME}"
ACR_URL="${AZURE_ACR_URL}"
ACR_USER="${AZURE_ACR_USER}"
ACR_PASS="${AZURE_ACR_PASS}"
FIXED_REPO="tnext_devlink"

REPO_URL="https://tssconsultancy.visualstudio.com/TrackWizzNext/_git/TrackWizzNext"
REPO_DIR="/datadisk/home/pritesh.bhatasana/image-builder/TrackWizzNext"

# ─── Inputs from environment (set by server.js) ───────────────────────────────
BRANCH="${DEPLOY_BRANCH}"
BUILD_NO="${DEPLOY_VERSION}"
# DEPLOY_SERVICES is comma-separated suffixes e.g. "apilogservice,emailservice"
IFS=',' read -ra SELECTED_SERVICES <<< "${DEPLOY_SERVICES}"

get_time() { date +"%Y-%m-%d %H:%M:%S"; }

echo "========================================================"
echo "  TrackWizz Deploy"
echo "  Branch  : $BRANCH"
echo "  Version : $BUILD_NO"
echo "  Services: ${DEPLOY_SERVICES}"
echo "========================================================"

# ─── Clone or update repo ─────────────────────────────────────────────────────
if [ ! -d "$REPO_DIR/.git" ]; then
    echo "📥 Cloning repo for the first time..."
    git clone --no-checkout "$REPO_URL" "$REPO_DIR"
fi

echo "🔀 Fetching and switching to branch: $BRANCH"
cd "$REPO_DIR"
git fetch --all --prune -q

if ! git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null 2>&1; then
    echo "❌ Branch '$BRANCH' not found on remote."
    exit 1
fi

git checkout "$BRANCH" -q 2>/dev/null || git checkout -B "$BRANCH" "origin/$BRANCH" -q
git pull origin "$BRANCH" -q
echo "✅ On branch '$(git rev-parse --abbrev-ref HEAD)' — $(git log -1 --format='%h %s')"
cd -

# ─── ACR login ────────────────────────────────────────────────────────────────
echo "🔑 Logging into ACR..."
echo "$ACR_PASS" | docker login "$ACR_URL" -u "$ACR_USER" --password-stdin &>/dev/null
echo "✅ ACR login successful."

# ─── Service definitions ──────────────────────────────────────────────────────
# Format: TYPE|suffix|extra1|extra2|extra3
declare -A SVC_DEF
SVC_DEF["apilogservice"]="DOTNET|apilogservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.APILog/ApiLogService/ApiLogService.csproj|APILog"
SVC_DEF["configurationservice"]="DOTNET|configurationservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.Configuration/ConfigurationService/ConfigurationService.csproj|Configuration"
SVC_DEF["custinfoservice"]="DOTNET|custinfoservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.CustomerInformation/CustInfoService/CustInfoService.csproj|CustomerInformation"
SVC_DEF["customerstoreservice"]="DOTNET|customerstoreservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.CustomerStore/CustomerStoreService/CustomerStoreService.csproj|CustomerStore"
SVC_DEF["dbupgradeservice"]="DOTNET|dbupgradeservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.DBUpgrade/DBBackupUtility/DBBackupUtility.csproj|DBUpgrade"
SVC_DEF["dmsservice"]="DOTNET|dmsservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.DMS/DMSService/DMSService.csproj|DMS"
SVC_DEF["emailservice"]="DOTNET|emailservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.Email/EmailService/EmailService.csproj|Email"
SVC_DEF["reportservice"]="DOTNET|reportservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.Report/ReportService/ReportService.csproj|Report"
SVC_DEF["schedulerservice"]="DOTNET|schedulerservice|TrackWizz/TrackWizzSaaSService/src/TrackWizzSaaS.Service.Scheduler/SchedulerService/SchedulerService.csproj|Scheduler"
SVC_DEF["ckyc_search_download_service"]="JAVA|ckyc_search_download_service|ckyc"
SVC_DEF["ckycsubmission"]="JAVA|ckycsubmission|ckyc"
SVC_DEF["ckycnotification"]="JAVA|ckycnotification|ckyc"
SVC_DEF["rekyc"]="JAVA|rekyc|ckyc"
SVC_DEF["jconfig"]="JAVA|jconfig|jconfig"
SVC_DEF["screeningappservice"]="UI|screeningappservice|screening|ScreeningApp|Screening"
SVC_DEF["commonappservice"]="UI|commonappservice|common|CommonApp|Common"
SVC_DEF["shellappservice"]="UI|shellappservice|shell|ShellApp|Shell"

# ─── Java pre-builds (deduplicate by project) ─────────────────────────────────
declare -A java_built
for suffix in "${SELECTED_SERVICES[@]}"; do
    suffix=$(echo "$suffix" | xargs)
    def="${SVC_DEF[$suffix]}"
    [ -z "$def" ] && continue
    IFS='|' read -r s_type _ internal_name <<< "$def"
    if [ "$s_type" == "JAVA" ] && [ -z "${java_built[$internal_name]}" ]; then
        echo "☕ Gradle build: $internal_name"
        (cd "$REPO_DIR/trackwizzjava" && ./gradlew :services:${internal_name}:clean :services:${internal_name}:build -q -x test) || exit 1
        java_built[$internal_name]=1
        echo "✅ Gradle done: $internal_name"
    fi
done

# ─── Build & push loop ────────────────────────────────────────────────────────
SAFE_BRANCH="${BRANCH//\//_}"
echo "--------------------------------------------------------"
echo "Deployment started at: $(get_time)"
echo "--------------------------------------------------------"

for suffix in "${SELECTED_SERVICES[@]}"; do
    suffix=$(echo "$suffix" | xargs)
    def="${SVC_DEF[$suffix]}"
    if [ -z "$def" ]; then
        echo "⚠️  Unknown service: '$suffix' — skipping."
        continue
    fi

    start_sec=$SECONDS
    IFS='|' read -r s_type _ f1 f2 f3 <<< "$def"
    IMAGE_TAG="${ACR_URL}/${FIXED_REPO}:trackwizznext${suffix}__${SAFE_BRANCH}_${BUILD_NO}"

    echo ""
    echo "[$(get_time)] ▶ STARTING: $suffix"

    if [ "$s_type" == "DOTNET" ]; then
        proj_path="$f1"
        folder_name="$f2"
        STAGING_DIR="/tmp/staging_${suffix}"
        mkdir -p "$STAGING_DIR"

        echo "🔨 Publishing .NET..."
        dotnet publish "$REPO_DIR/$proj_path" -c Release -o "$STAGING_DIR" --no-restore --verbosity quiet
        cp -r "$REPO_DIR/TrackWizz/TrackWizzSaaSService/docker/$folder_name/"* "$(dirname "$STAGING_DIR")/"
        BUILD_CONTEXT="$(dirname "$STAGING_DIR")"

    elif [ "$s_type" == "JAVA" ]; then
        internal_name="$f1"
        STAGING_DIR="/tmp/staging_${suffix}"
        mkdir -p "$STAGING_DIR"

        echo "📦 Staging Java artifact..."
        cp "$REPO_DIR/trackwizzjava/services/$internal_name/build/libs/$internal_name-1.0.0.jar" "$STAGING_DIR/"
        cp "$REPO_DIR/trackwizzjava/services/$internal_name/Dockerfile_All" "$STAGING_DIR/Dockerfile"
        cp "$REPO_DIR/trackwizzjava/services/$internal_name/src/main/resources/"*.yml "$STAGING_DIR/"
        BUILD_CONTEXT="$STAGING_DIR"

    elif [ "$s_type" == "UI" ]; then
        nx_project="$f1"
        docker_folder="$f2"
        docker_path="$f3"
        STAGING_DIR="/tmp/staging_${suffix}"
        mkdir -p "$STAGING_DIR/$docker_path"

        echo "🖥  Building UI with nx..."
        (cd "$REPO_DIR/TrackWizz/TrackWizzSaaSUI/trackwizz-saas" \
            && npm ci --silent \
            && npx nx build "$nx_project" --prod --no-progress > /dev/null 2>&1)
        cp -r "$REPO_DIR/TrackWizz/TrackWizzSaaSUI/trackwizz-saas/dist/apps/$nx_project/"* "$STAGING_DIR/$docker_path/"
        cp -r "$REPO_DIR/TrackWizz/TrackWizzSaaSService/docker/$docker_folder/"* "$STAGING_DIR/"
        BUILD_CONTEXT="$STAGING_DIR"
    else
        echo "⚠️  Unsupported type '$s_type' for $suffix — skipping."
        continue
    fi

    echo "🐳 Building Docker image: $IMAGE_TAG"
    docker build --progress=plain -t "$IMAGE_TAG" "$BUILD_CONTEXT"
    docker push "$IMAGE_TAG"

    rm -rf "$STAGING_DIR"
    echo "[$(get_time)] ✅ COMPLETED: $suffix (took $((SECONDS - start_sec))s)"
    echo "--------------------------------------------------------"
done

echo ""
echo "========================================================"
echo "  Deployment finished at: $(get_time)"
echo "========================================================"
