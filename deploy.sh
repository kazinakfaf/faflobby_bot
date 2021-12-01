source ./.env
rsync -va --exclude 'vendor'  --exclude '.git' --exclude 'tmp' --exclude 'data' --exclude 'env' --exclude 'Gemfile.lock' "$PWD/" $DEPLOY_SSH:$DEPLOY_DIRECTORY
ssh $DEPLOY_SSH "cd $DEPLOY_DIRECTORY; docker-compose up -d"
ssh $DEPLOY_SSH "cd $DEPLOY_DIRECTORY; docker-compose restart ruby"