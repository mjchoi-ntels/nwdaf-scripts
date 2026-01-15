import sys

from db_config import config
from minio_utils import get_s3_client, get_model_versions

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: python exec_get_all_versions.py <model_type>')
        exit(-1)

    model_type = sys.argv[1]

    if model_type not in ['gru', 'lstm']:
        print('model_type must be gru or lstm')
        exit(-1)

    s3_client = get_s3_client(
        config['minio_server'], config['minio_access_key'], config['minio_secret_key']
    )

    versions = get_model_versions(s3_client, model_type)

    print(versions)