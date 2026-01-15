import sys
from time import sleep

from db_config import config
from minio_utils import get_s3_client, get_model_versions, set_model
from triton_utils import get_triton_client, reload_model


def is_int(s):
    try:
        int(s)
        return True
    except (TypeError, ValueError):
        return False


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print('Usage: python exec_set_version.py <model_type> <model_version>')
        exit(-1)

    model_type = sys.argv[1]
    model_version = sys.argv[2]

    if model_type not in ['gru', 'lstm']:
        print('model_type must be gru or lstm')
        exit(-1)

    s3_client = get_s3_client(
        config['minio_server'], config['minio_access_key'], config['minio_secret_key']
    )

    versions = get_model_versions(s3_client, model_type)

    if len(versions) == 0:
        print('No versions found in model-repo')
        exit(-1)

    if model_version == '/latest':
        versions = list(sorted(filter(is_int, versions), key=int))
        model_version = versions[-1]
    elif model_version not in versions:
        print(f'{model_version} is not a valid version')
        exit(-1)

    try:
        set_model(s3_client, model_type, model_version)
        print(f'Successfully set version {model_version} to model-repo')
    except Exception as e:
        print(f'Error occurred in set_model: {e}')
        print(f'Failed to set version {model_version}')
        exit(-1)

    sleep(3)

    try:
        triton_client = get_triton_client(config['triton_server'])
        reload_model(triton_client, model_type)
        print(f'Successfully reloaded model {model_type} version {model_version} to Triton server')
    except Exception as e:
        print(f'Error occurred in reload_model: {e}')
        print('Failed to connect to Triton server')
        exit(-1)