#!/bin/bash

curdate=$(date +"%Y-%m-%d")

# Make sure we've got the previous certificate
if [ ! -d /etc/letsencrypt ]; then
    echo "Existing certificate not found on server.  Pulling a backup copy from S3"
    aws s3 cp --recursive s3://lencrypt /etc/letsencrypt
    # Restore symlinks
    cd /etc/letsencrypt/live/www.gitenberg.org/
    rm -f ./*.pem
    for i in `cat symlinks`;
    do
        NAME=$(echo $i | cut -f1 -d"|")
        LNK=$(echo $i | cut -f2 -d"|")
        ln -s $LNK $NAME
    done
else
    echo "Certificate already present locally"
fi

# Grab the modification time for the certificate
OLD_MOD_TIME=$(stat -c %Y /etc/letsencrypt/live/www.gitenberg.org/cert.pem)

# Download letsencrypt client
if [ -d /opt/letsencrypt/letsencrypt ]; then
    cd /opt/letsencrypt/letsencrypt
    git pull
else
    git clone https://github.com/letsencrypt/letsencrypt /opt/letsencrypt/letsencrypt
    cd /opt/letsencrypt/letsencrypt
fi

PROJECT_DIR="/opt/python/current/app"

# This will renew the certificate
./letsencrypt-auto certonly --webroot -w "$PROJECT_DIR"/letsencrypt/ -d www.gitenberg.org -d gitenberg.org --debug --agree-tos --non-interactive --keep-until-expiring --config /opt/letsencrypt/cli.ini

# Check that everything succeeded
if [ $? -ne 0 ]; then
    echo "An error occurred with the letsencrypt cert process."
else
    NEW_MOD_TIME=$(stat -c %Y /etc/letsencrypt/live/www.gitenberg.org/cert.pem)
    if [ "${OLD_MOD_TIME}" != "${NEW_MOD_TIME}" ]; then
        # Certificate file was modified, proceed
        echo "Successfully renewed the certificate.  Upload to AWS IAM."
        aws iam upload-server-certificate --server-certificate-name gitenberg-lencrypt-${curdate} --certificate-body file:///etc/letsencrypt/live/www.gitenberg.org/cert.pem --private-key file:///etc/letsencrypt/live/www.gitenberg.org/privkey.pem --certificate-chain file:///etc/letsencrypt/live/www.gitenberg.org/chain.pem | tee /tmp/aws_upload.response

        if [ $? -ne 0 ]; then
            echo "An error occurred uploading the certificate to AWS IAM"
        else
            cert_arn=$(grep 'Arn' /tmp/aws_upload.response | sed -e "s/^.*\"arn:/arn:/" -e "s/\",\s*$//")
            echo "Found ARN ${cert_arn} for uploaded certificate"
            # ARN contains a / character, so use alternate separators for sed command
            sed -e "s~REPLACEME~${cert_arn}~" /tmp/arn_options.json > /tmp/arn_options_${curdate}.json
            # This command is BROKEN
            # update-environment will break the environment if it is sent bad
            # configuration params, which seems to include basically any
            # configuration that changes the SSL Cert.  So just don't do it.  
            #echo "Update environment configuration with the new certificate"
            #aws elasticbeanstalk update-environment --region us-east-1 --environment-name giten-site-dev --option-settings file:///tmp/arn_options_${curdate}.json
            # Send an email instead:
            echo -e "The SSL Certificate from Let's Encrypt for the gitenberg.org site has been renewed.  Please update it via the Amazon admin console for the site.\n\n\tNew Certificate: gitenberg-lencrypt-${curdate}" | mail -s "New gitenberg.org certificate gitenberg-lencrypt-${curdate}" eric@hellman.net,moss.paul@gmail.com
        fi

        echo "Upload Certs to S3 for future reference"
        # S3 doesn't store symlinks, so keep a manual copy
        cd /etc/letsencrypt/live/www.gitenberg.org/
        rm -f symlinks
        touch symlinks
        for i in `ls *.pem`;
        do
            LNK=$(readlink $i)
            echo "$i|$LNK" >> symlinks
        done
        aws s3 cp --recursive /etc/letsencrypt s3://lencrypt/
    else
        echo "Certificate file not modified, but the process succeeded. Assuming no renewal happened."
    fi
fi

# Make *sure* we don't lose the logs in the event of instance restart
aws s3 cp /var/log/letsencrypt_renewal.log s3://lencrypt/letsencrypt_renewal.log-${curdate}

exit 0
