import os
import re
import pandas as pd
import numpy as np
import random
import pickle
import glob
import time
import shutil
import copy
from tqdm import tqdm, trange
import gc
from datetime import datetime, timedelta
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler, MinMaxScaler, LabelEncoder
from sklearn.metrics import mean_absolute_error
from sklearn.metrics import mean_squared_error
from collections import defaultdict
import traceback
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
from torch.cuda.amp import autocast, GradScaler
import clickhouse_connect
import tritonclient.http as httpclient
import boto3
import hashlib
from architecture import *
from minio_utils import get_s3_client, get_current_version


def write_log(msg):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open('progress.log', 'a') as f:
        f.write(f"[{now}] {msg}\n")
    print(f"[{now}] {msg}")

"""
====================================================================================
기본 전처리 함수 및 LOAD, SAVE 함수
====================================================================================
"""

# Set the seed for reproducibility
def set_seed(seed):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed(seed)
        torch.cuda.manual_seed_all(seed)
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.benchmark = False


def train_hist_load(*args):
    """ 학습 이력 조회하는 함수 """
    config = args[0]

    # get the current model version
    try:
        endpoint_url = config['minio_server']
        access_key = config['minIO_access_key']
        secret_key = config['minIO_secret_key']
        bucket_name = config['bucket_name']
        model_type = config['model_type']
        ## minio util
        s3_client = get_s3_client(endpoint_url, access_key, secret_key)
        version = get_current_version(s3_client, model_type, bucket_name)

        model_seq = version
    except:
        model_seq = f"(select MAX(model_seq) from {config['model_hist_table_name']} where model_type = '{model_type}')"

    try:
        # 개발 TB
        client = clickhouse_connect.get_client(
                            host=config['db_host'],
                            port=config['db_port'],
                            username=config['db_username'],
                            password=config['db_password'],
                            database=config['db_database']
                        )



        # 모델 학습 쿼리
        query = f"select cell_list, model_seq from {config['model_hist_table_name']} where model_type = '{config['model_type']}' and model_seq = {model_seq}"



        data = client.query(query)
        data = pd.DataFrame(data.result_rows, columns=data.column_names)
        client.close()

        print("==================== 학습 이력 관리 로드 완료 ====================")

    except Exception as e:
        print(f'Error occurred in train_hist_load: {e}')

    return data


 
    

def train_data_load(*args, client=None):
    """ 학습데이터 조회하는 함수 """

    st_time = time.time()
    config = args[0]
    dt_ =  args[1]


    close_after = False

    try:

        # 1) 시간 처리
        dt_ = pd.to_datetime(dt_)
        dt_end = dt_ + timedelta(hours=config['train_loop_time'])
        dt_str = dt_.strftime('%Y-%m-%d %H:%M:%S')
        dt_end_str = dt_end.strftime('%Y-%m-%d %H:%M:%S')

        # 2) 컬럼 구성
        dep_cols = config.get('depcol_name', [])
        indep_cols = config.get('indepcol_name', [])
        base_cols = ['cell_type', 'freq_type', 'window_end', 'window_start', 'prb_usage_rate', 'enb_cell_id']
        # 중복 제거
        all_cols = base_cols + [c for c in dep_cols if c not in base_cols] + [c for c in indep_cols if c not in base_cols]
        select_cols_sql = ', '.join(all_cols)

        # 3) 쿼리 구성
        table_name = config['train_table_name']

        query = (
            f"SELECT {select_cols_sql} "
            f"FROM {table_name} "
            f"WHERE window_end >= '{dt_str}' AND window_end <= '{dt_end_str}' "
            f"ORDER BY enb_cell_id, window_end;"
        )


#         # n개 기지국
#         query = (
#             f"SELECT {select_cols_sql} "
#             f"FROM {table_name} "
#             f"WHERE window_end >= '{dt_str}' AND window_end < '{dt_end_str}' and enb_cell_id IN (select enb_cell_id from (select enb_cell_id from {config['train_table_name']} where window_end >= '{dt_}' and window_end < '{dt_end}' group by enb_cell_id order by right(enb_cell_id, 3), enb_cell_id limit {config['train_num']}))"
#             f"ORDER BY enb_cell_id, window_end;"
#         )
        
    
#         print(query)
          

        # 4) 클라이언트 생성
        
        if client is None:
            client = clickhouse_connect.get_client(
                                host=config['db_host'],
                                port=config['db_port'],
                                username=config['db_username'],
                                password=config['db_password'],
                                database=config['db_database']
                            )
            close_after = True
        
        # 5) 실행
        data = client.query_df(query)

        # 6) 빈 결과 처리
        if data.empty:
            print(f"[WARN] 데이터 없음: 기간={dt_str} ~ {dt_end_str}")
        else:
            print(f"[INFO] 로드된 행수: {len(data):,}, 컬럼수: {data.shape[1]}")

        # 7) 후처리(시간 컬럼 형식 정규화)
        if 'window_end' in data.columns:
            data['window_end'] = pd.to_datetime(data['window_end'])

        return data

    except Exception as e:
        print(f"[ERROR] train_data_load 실패: {e}")
        return pd.DataFrame()

    finally:
        ed_time = time.time()
        diff_m = (ed_time - st_time) / 60.0
        print(f"[INFO] 데이터 로드 수행 시간: {diff_m:.2f}분")
        if close_after:
            try:
                client.close()
            except Exception:
                pass
        print("==================== 학습 데이터 로드 완료 ====================")


        



# def test_data_load(*args):
#     """ 추론 데이터 조회하는 함수 """

#     st_time = time.time()
    
#     config = args[0]
#     now_dt = args[1]

#     client = clickhouse_connect.get_client(
#         host=config['db_host'],
#         port=config['db_port'],
#         username=config['db_username'],
#         password=config['db_password'],
#         database=config['db_database']
#     )

#     # 컬럼 구성
#     dep_cols = config.get('depcol_name', [])          # 피처용 컬럼들
#     target_cols = config.get('indepcol_name', [])     # 타깃 컬럼들 (ex. ['prb_usage_rate'])

#     base_cols = ['cell_type', 'freq_type', 'window_end', 'window_start', 'enb_cell_id']

#     # 중복 제거하면서 base + dep + target 모두 포함
#     all_cols = []
#     for col in base_cols + dep_cols + target_cols:
#         if col not in all_cols:
#             all_cols.append(col)

#     select_cols_sql = ', '.join(all_cols)

#     table_name = config['test_table_name']

#     # 최종 쿼리 (전체 기지국 기준 테스트용)
#     query = (
#         f"SELECT {select_cols_sql} "
#         f"FROM {table_name} "
#         f"WHERE 1 = 1 "
#         f"  AND toDateTime(window_end) >= "
#         f"      subtractMinutes(toDateTime('{now_dt}'), {config['sequence_length']*5}) "
#         f"  AND toDateTime(window_end) <= toDateTime('{now_dt}') "
#         f"  AND toMinute(toDateTime(window_end)) % 5 = "
#         f"      toMinute(toDateTime('{now_dt}')) % 5 "
#         f"ORDER BY enb_cell_id, window_end;"
#     )
    
#     print(query)

#     data = client.query_df(query)
#     client.close()

#     ed_time = time.time()
#     diff_time = ed_time - st_time
#     print(f"[INFO] 데이터 로드 수행 시간 : {diff_time/60:.1f} 분")
#     print("==================== 예측 데이터 로드 완료 ====================")

#     return data


def test_data_load(config, now_dt, shard_id=0, num_shards=1):
    """ 추론 데이터 조회하는 함수 """

    st_time = time.time()
    
    # config = args[0]
    # now_dt = args[1]
    # shard_id = args[2]
    # num_shards = args[3]
    
    shard_id = int(shard_id)
    num_shards = int(num_shards)

    client = clickhouse_connect.get_client(
        host=config['db_host'],
        port=config['db_port'],
        username=config['db_username'],
        password=config['db_password'],
        database=config['db_database']
    )

    # 컬럼 구성
    dep_cols = config.get('depcol_name', [])          # 피처용 컬럼들
    target_cols = config.get('indepcol_name', [])     # 타깃 컬럼들 (ex. ['prb_usage_rate'])

    base_cols = ['cell_type', 'freq_type', 'window_end', 'window_start', 'enb_cell_id']

    # 중복 제거하면서 base + dep + target 모두 포함
    all_cols = []
    for col in base_cols + dep_cols + target_cols:
        if col not in all_cols:
            all_cols.append(col)

    select_cols_sql = ', '.join(all_cols)
    table_name = config['test_table_name']
    seq_min = int(config['sequence_length']) * 5

    # 최종 쿼리 (분산 처리용)
    query = f"""
    SELECT {select_cols_sql}
    FROM {table_name}
    WHERE 1 = 1
        AND toDateTime(window_end) >= subtractMinutes(toDateTime('{now_dt}'), {seq_min})
        AND toDateTime(window_end) <= toDateTime('{now_dt}')
        AND toMinute(toDateTime(window_end)) % 5 = toMinute(toDateTime('{now_dt}')) % 5
        AND modulo(cityHash64(toString(enb_cell_id)), {num_shards}) = {shard_id}
    ORDER BY enb_cell_id, window_end
    """
    
    print(query)

    data = client.query_df(query)
    client.close()

    ed_time = time.time()
    diff_time = ed_time - st_time
    print(f"[INFO] 데이터 로드 수행 시간 : {diff_time/60:.1f} 분")
    print("==================== 예측 데이터 로드 완료 ====================")

    return data



def acc_data_load(*args):
    """ 정확도 체크용 데이터 조회하는 함수 """

    st_time = time.time()

    config = args[0]
    miuntes_bef = args[1]
    now = args[2]


    client = clickhouse_connect.get_client(
                        host=config['db_host'],
                        port=config['db_port'],
                        username=config['db_username'],
                        password=config['db_password'],
                        database=config['db_database']
                    )

    base_col = ['cell_id', 'cell_type', 'window_end', 'freq_type', 'model_type', 'prb_usage_predicted']
    select_cols_sql = ', '.join(base_col)
    table_name = config['result_table_name']

    pred_query = (
            f"SELECT {select_cols_sql} "
            f"FROM {table_name} "
            f"WHERE DATE_SUB(toDateTime('{miuntes_bef.strftime('%Y-%m-%d %H:%M:00')}'), INTERVAL 45 MINUTE) "
            f" AND window_end < DATE_SUB(toDateTime('{now.strftime('%Y-%m-%d %H:%M:00')}'), INTERVAL 45 MINUTE) "
            f" AND toMinute(window_end)%5=0 "
            f" AND model_type = '{config['model_type']}'; "
            )
    # print(pred_query)


    pred_data = client.query(pred_query)
    pred_data = pd.DataFrame(pred_data.result_rows, columns=pred_data.column_names)
    print("==================== 예측 결과 데이터 로드 완료 ====================")


    base_col = ['enb_cell_id', 'cell_type', 'freq_type', 'window_end', 'prb_usage_rate']
    select_cols_sql = ', '.join(base_col)
    table_name = config['train_table_name']


    true_query = (
    f"SELECT {select_cols_sql} "
    f"FROM {table_name} "
    f"WHERE enb_cell_id IN {tuple(pred_data['cell_id'].unique())} "
    f" AND window_end >= DATE_SUB(toDateTime('{miuntes_bef.strftime('%Y-%m-%d %H:%M:00')}'), INTERVAL 45 MINUTE) "
    f" AND window_end < DATE_SUB(toDateTime('{now.strftime('%Y-%m-%d %H:%M:00')}'), INTERVAL 45 MINUTE) ;"
    )

    # print(true_query)

    true_data = client.query(true_query)
    true_data = pd.DataFrame(true_data.result_rows, columns=true_data.column_names)
    print("==================== 실제 데이터 로드 완료 ====================")


    return true_data, pred_data






def saveMD(*args, **kwargs):
    """ 객체 파일 및 DB 데이터 저장 함수 """

    config = args[0]
    input_name = kwargs.get('nm')


    if input_name.startswith(('scaler', 'encoder', 'md_config')):
        seq = kwargs.get('seq', 0)
        path = create_model_folders(config, seq)
        path = '/'.join(path.split('/')[:-1])

        path_nm = path+'/'+input_name+'.pkl'
        if len(args)>1:
            pickle.dump(args[1], open(path_nm, 'wb'))
        else: 
            pickle.dump(args[0], open(path_nm, 'wb'))
    

    else:

         # 개발 TB
        client = clickhouse_connect.get_client(
                        host=config['db_host'],
                        port=config['db_port'],
                        username=config['db_username'],
                        password=config['db_password'],
                        database=config['db_database']
                    )


        if 'accuracy' in input_name:

            client.insert(config['acc_table_name'], args[1])
            print("====================  모델 성능 관리 저장 완료 ====================")

        if 'predict' in input_name:

            client.insert(config['result_table_name'], args[1])
            print("====================  예측 결과 저장 완료 ====================")

        if 'hist' in input_name:

            client.insert(config['model_hist_table_name'], args[1])
            print("====================  모델 학습 이력 관리 저장 완료 ====================")


        if 'cells' in input_name:


            # 기존 추론 seq 삭제
            query = f"DELETE FROM {config['model_hist_train_cells']} WHERE model_type = '{config['model_type']}'"
            client.query(query)

            # 학습 모델 insert
            client.insert(config['model_hist_train_cells'], args[1])
            print("====================  모델 학습 셀 이력 관리 저장 완료 ====================")

        client.close()



def loadMD(*args, **kwargs):
    """ 객체 파일 및 모델 로드 함수 """

    config = args[0]
    key = kwargs.get('nm')
    base_path = config['model_save_path']

    # -------------------------------
    # 1) scaler / encoder / md_config / train_cell 등 pickle 객체
    # -------------------------------
    if any(nm in key for nm in ['scaler', 'encoder', 'md_config', 'train_cell']):
        # 내부 장비 기준) 해당 폴더 내의 모든 파일 목록을 가져옴
        file_list = [
            os.path.join(root, f)
            for root, _, files in os.walk(base_path)
            for f in files
        ]
        candidates = [filenm for filenm in file_list if key in filenm]

        if not candidates:
            raise FileNotFoundError(
                f"[ERROR] '{key}' 이(가) 포함된 객체 파일(.pkl)을 찾지 못했습니다. "
                f"검색 경로: {base_path}"
            )

        # 여러 개라면 정렬 후 마지막(가장 최근) 사용
        load_nm = sorted(candidates)[-1]
        print(f"[INFO] load object: {load_nm}")
        obj = pickle.load(open(load_nm, 'rb'))
        return obj

    # -------------------------------
    # 2) 모델(.pt) 로드
    # -------------------------------
    if 'model' in key:
        base_path = config['model_save_path']
        
        # 경로가 '//'로 시작하면 './'로 자동 수정
        if base_path.startswith('//'):
            base_path = '.' + base_path[1:]
    
    
        # .ipynb_checkpoints 제거
        for root, dirs, files in os.walk(base_path):
            if '.ipynb_checkpoints' in dirs:
                shutil.rmtree(os.path.join(root, '.ipynb_checkpoints'))
    
        # 모든 하위 폴더에서 .pt 검색
        model_paths = []
        for root, _, files in os.walk(base_path):
            for f in files:
                if f.endswith('.pt'):
                    model_paths.append(os.path.join(root, f))
    
        print(f"model path : {model_paths}")
    
        if not model_paths:
            raise FileNotFoundError(
                f"[ERROR] 모델 파일(.pt)을 찾지 못했습니다: {base_path}"
            )
    
        # 최신 모델 사용
        model_path = sorted(model_paths)[-1]
        print(f"[INFO] load model: {model_path}")
    
        # TorchScript 로드 (정답)
        load_model = torch.jit.load(model_path, map_location=torch.device('cpu'))
        load_model.eval()
    
        return load_model


    # -------------------------------
    # 3) 매칭되는 분기가 없을 때
    # -------------------------------
    raise ValueError(f"[ERROR] loadMD에서 지원하지 않는 nm 값입니다: {key}")



"""
====================================================================================
데이터 전처리 함수
====================================================================================
"""
def create_model_folders(config, seq):
    # 현재 날짜를 "YYYY-MM-DD" 형식으로 가져오기
    # today_date = datetime.today().strftime('%Y%m%d')

    # 저장 폴더 경로 설정
    os.makedirs(config['model_save_path'], exist_ok=True)

    # 오늘 날짜로 된 폴더 경로 설정
    # model_folder_name = config['model_type']+'_'+ today_date
    
    # unix timestamp로 폴더 경로 설정
    model_folder_name = config['model_type']+'_'+ str(seq)
    
    today_folder = os.path.join(config['model_save_path'], model_folder_name)
    os.makedirs(today_folder, exist_ok=True)

    # "1" 폴더 경로 설정
    folder_1 = os.path.join(today_folder, '1')

    # 폴더들이 존재하지 않으면 생성
    os.makedirs(folder_1, exist_ok=True)
    print(f"폴더 생성 완료: {folder_1}")

    return folder_1



def shift_y(df, group_col, target_col, shift_n):
    group_ids = df[group_col].values
    values = df[target_col].values

    shifted = np.full_like(values, fill_value=np.nan, dtype='float32')

    # 그룹 경계 인덱스 추출 (각 그룹 시작 위치)
    _, idx_starts = np.unique(group_ids, return_index=True)
    idx_starts = np.append(idx_starts, len(group_ids))  # 마지막 그룹 끝 처리

    for i in range(len(idx_starts) - 1):
        start, end = idx_starts[i], idx_starts[i + 1]
        group_size = end - start

        if group_size > abs(shift_n):
            if shift_n > 0:
                shifted[start + shift_n:end] = values[start:end - shift_n]
            else:
                shifted[start:end + shift_n] = values[start - shift_n:end]

    return shifted






def sort_data(*args):

    data = args[0]
    config = args[1]
    
    # 0. 컬럼타입 설정

    # start = time.time()

    data['day_of_week'] = data['day_of_week'].astype(int)
    data['is_weekend'] = data['is_weekend'].astype(int)
    data['hh'] = data['hh'].astype(int)
    data['window_end'] = pd.to_datetime(data['window_end'])

    if config['type'] == 'train':
        data[config['scaler_col']+config['indepcol_name']] = data[config['scaler_col']+config['indepcol_name']].astype(float)

    else:
        data[config['scaler_col']] = data[config['scaler_col']].astype(float)

    # end = time.time()
    # print(f"컬럼타입 설정 처리 시간 : {end - start:.2f}초")
        

    # 2. 중복 삭제
    data = data.loc[~data.duplicated(['enb_cell_id', 'window_end'])]
 
    
    # 3. 모듈별 시간 풀셋 생성
        # 전체 시간 범위
  
    global_start = data['window_end'].min()
    global_end = data['window_end'].max()
    full_time_index = pd.date_range(start=global_start, end=global_end, freq='5min')
       
        # 고유 모듈 ID (정렬 생략해서 속도 개선)
    module_ids = data['enb_cell_id'].unique()
    
        # 모든 모듈 × 시간 조합 만들기
    full_index = pd.MultiIndex.from_product([module_ids, full_time_index], names=['enb_cell_id', 'window_end']).to_frame(index=False)

        # 기존 데이터와 merge
    data = pd.merge(full_index, data, on=['enb_cell_id', 'window_end'], how='left')

    del full_index, full_time_index, module_ids
    gc.collect()

    
    
    # 4. 결측값 선형보간
    data[config['scaler_col']] = data[config['scaler_col']].interpolate(method = 'linear')

    
    
    # 5. 요일/시간 변수 변환
    # start = time.time()
    data['week_sin'] = np.sin(2 * np.pi * data['day_of_week']/ 7)
    data['week_cos'] = np.cos(2 * np.pi * data['day_of_week']/ 7)

    data['hour_sin'] = np.sin(2 * np.pi * data['hh'] / 24)
    data['hour_cos'] = np.cos(2 * np.pi * data['hh'] / 24)

    config['feature_col'] = ['week_sin', 'week_cos', 'hour_sin', 'hour_cos']+config.get('depcol_name')
         
    
    # 7. 기지국별 타겟값 shift
    if config['type'] == 'train':
        
        col = config['indepcol_name'][0]
        data[col] = shift_y(data, group_col='enb_cell_id', target_col=col, shift_n=config['y_shift'])
        data = data.dropna().reset_index(drop=True)

  
    
    return data

    

    

def label_encoder(data, config):

    le = LabelEncoder()
    data['enb_cell_id_encoder'] = le.fit_transform(data[config['split_col'][0]])
    config['feature_col'] = ['enb_cell_id_encoder']+config['feature_col']

    return le, data, config



def apply_log_transform(df, cols):
  
    for col in cols:
        # 로그 변환 전 0 이하 값이 있다면 shift
        if (df[col] <= 0).any():
            shift = abs(df[col].min()) + 1
            df[col] = np.log1p(df[col] + shift)
        else:
            df[col] = np.log1p(df[col])
    return df

    
# Scaler 객세 생성/저장
def scaling(data, config, target):

    if config['scaler'] == 'log1p':
        return apply_log_transform(data, config[target]), None
    
    else:
        scaler = copy.deepcopy(config['scaler'])    
        data[config[target]] = scaler.fit_transform(data[config[target]])
        return data, scaler

    

def update_usage_groups(usage_groups_old, usage_groups_new):
    updated_groups = {}
    used_ids = set()

    for key in usage_groups_new:
        new_ids = set(usage_groups_new[key]) - used_ids
        updated_groups[key] = list(new_ids)
        used_ids.update(new_ids)

    return updated_groups



# describe() 결과 형식화
def pretty_print_describe(df):
    desc = df.describe().T  # 전치해서 보기 좋게
    desc = desc.round(2)    # 소수점 2자리로 반올림
    return desc


# lstm_20251118_3hour_version1에 사용/ 20251126_3hour_version2에 사용
def train_preprocessing(*args, **kwargs):
    try:

        data = args[0]
        config = args[1]
        loop_n = kwargs.get('loop_n')
        

        # 기본 전처리
        data = sort_data(data, config)

        
        # 학습 건수가 충분하지 않은 기지국 제외
        # start = time.time()
        id_counts = data.groupby('enb_cell_id', sort=False).size()
        min_required_len = config['sequence_length'] + config['y_shift'] + config.get('val_length', config['sequence_length'] + 1)
        valid_mask = data['enb_cell_id'].map(id_counts) >= min_required_len
        data = data[valid_mask]
        
    
        # invalid_ids = id_counts[id_counts < config['sequence_length']].index
    
        # end = time.time()
        # print(f"학습 건수가 충분하지 않은 기지국 제외 처리 시간 : {end - start:.2f}초")
    
    
        # ID 컬럼 인코딩/Scaler 객세 생성/저장
        if loop_n == 0:
            # start = time.time()
            
            # ID 컬럼 
            id_encoder, data, conifg = label_encoder(data, config)
            
            # Scaler 
            data, scaler_x = scaling(data, config, 'scaler_col')
            # data, scaler_y = scaling(data, config, 'indepcol_name')
    
    
            # end = time.time()
            # print(f"라벨인코딩&Scaler 객체 생성 처리 시간 : {end - start:.2f}초")
    
    
        else:
            id_encoder = args[2]
            scaler_x = args[3]
            # scaler_y = args[4]
    
            # start = time.time()
            
            # ID 컬럼 
            updated_classes = np.union1d(id_encoder.classes_, data[config['split_col'][0]].unique().tolist())
            id_encoder.classes_ = updated_classes
            data['enb_cell_id_encoder'] = id_encoder.transform(data[config['split_col'][0]])
            config['feature_col'] = ['enb_cell_id_encoder']+config['feature_col']
    
            
            # Scaler 
            if config['scaler'] == 'log1p':
                data, scaler_x = scaling(data, config, 'scaler_col')
                # data, scaler_y = scaling(data, config, 'indepcol_name')
            else:
                scaler_x.partial_fit(data[config['scaler_col']])
                # scaler_y.partial_fit(data[config['indepcol_name']])
    
                data[config['scaler_col']] = scaler_x.transform(data[config['scaler_col']])
                # data[config['indepcol_name']] = scaler_y.transform(data[config['indepcol_name']])
    
            # end = time.time()
            # print(f"라벨인코딩&Scaler 객체 생성 처리 시간 : {end - start:.2f}초")
    

    
        # feature_col 변수에 불필요한 인자 삭제
        remove_col = ['enb_cell_id', 'day_of_week']
        for col in remove_col:
            if col in config['feature_col']:
                config['feature_col'].remove(col)

        
        # 불필요한 변수 삭제
        del id_counts, valid_mask
        if loop_n != 0:
            del updated_classes
        
        gc.collect()


        return data.reset_index(drop=True), id_encoder, scaler_x
    except Exception as e:
        print(f'Error occurred in train_preprocessing: {e}')

        

        
        

def duration_nosignal(data, config):

    df_sorted = data.sort_values(by=['enb_cell_id', 'window_end'], ascending=[True, False])

    # 샘플링
    df_sampled = df_sorted.groupby('enb_cell_id').head(int(config['signal_cutoff'] / 5))

    # 과금값이 모두 null인 enb_cell_id 찾기
    nan_mask = df_sampled[config['scaler_col']].isna()
    nan_groups = nan_mask.groupby(df_sampled['enb_cell_id']).transform('all')
    nancell_index= df_sampled.loc[nan_groups.all(axis=1), 'enb_cell_id'].unique().tolist()

    return nancell_index



def test_preprocessing(data, config):
    start_time = time.time()

    # 1. 기본 정렬
    data = sort_data(data, config)

    # 2. 장기 무신호 기지국 제거
    del_cell = duration_nosignal(data, config)
    data = data[~data['enb_cell_id'].isin(del_cell)]
    print(f"장기 무신호 기지국 제거 후 Cell count : {data['enb_cell_id'].nunique()} / 추론 데이터 길이  : {len(data)}")


    # # 3. 학습된 기지국만 사용
    id_encoder = loadMD(config, nm='encoder_')
    trained_ids = id_encoder.classes_.tolist()
    data = data[data['enb_cell_id'].isin(trained_ids)]
    print(f"학습된 기지국만 필터링 후 Cell count : {data['enb_cell_id'].nunique()} / 추론 데이터 길이  : {len(data)}")

    # 4. ID 인코딩
    data['enb_cell_id_encoder'] = id_encoder.transform(data['enb_cell_id'])

    # feature_col 보정
    if 'enb_cell_id_encoder' not in config['feature_col']:
        config['feature_col'] = ['enb_cell_id_encoder'] + config['feature_col']

    # 5. 스케일링
    if config['scaler'] == 'log1p':
        data, _ = scaling(data, config, 'scaler_col')
    else:
        scaler_x = loadMD(config, nm='scaler_x_')
        data[config['scaler_col']] = scaler_x.transform(data[config['scaler_col']])

    # 불필요 컬럼 제거
    for col in ['enb_cell_id', 'day_of_week']:
        if col in config['feature_col']:
            config['feature_col'].remove(col)

    # 6. cell info
    cell_info = (
        data
        .drop_duplicates('enb_cell_id')
        [['enb_cell_id', 'cell_type', 'freq_type']]
        .reset_index(drop=True)
    )

    print(f"[INFO] Test preprocessing time: {(time.time() - start_time):.2f}s")

    return data.reset_index(drop=True), cell_info





def df_hist(data, config, date_list, train_cell_lst, info, train_result, seq_):

    # seq_ = 0
    # if not info.empty:
    #     seq_ = info['model_seq'].values[0]+1


    # AI 학습 이력 테이블
    if 'Success' in train_result:
        hist = pd.DataFrame([data.mean()])
        # hist['train_mape'] = np.where(hist['train_mape'] <= 0, 0, np.where(hist['train_mape'] >= 100, 100, hist['train_mape']))
        hist['train_mape'] = 0
        hist['model_type'] = config['model_type']
        hist['excution_start'] = pd.to_datetime(date_list[0])
        hist['excution_end'] = pd.to_datetime(date_list[-1])
        hist['cell_list'] = str(tuple(train_cell_lst))
        hist['model_seq'] = seq_
        hist['cell_count'] = len(train_cell_lst)
        hist['train_result'] = train_result

    if 'Fail' in train_result:
        hist = pd.DataFrame([data.mean()])
        hist['train_mae'] = 0
        hist['train_mse'] = 0
        hist['train_rmse'] = 0
        hist['train_mape'] = 0
        hist['model_type'] = config['model_type']
        hist['excution_start'] = pd.to_datetime(date_list[0])
        hist['excution_end'] = pd.to_datetime(date_list[-1])
        hist['cell_list'] = str(tuple(train_cell_lst))
        hist['model_seq'] = seq_
        hist['cell_count'] = len(train_cell_lst)
        hist['train_result'] = train_result


    # train_cells 테이블
    hist_cells = pd.DataFrame()
    hist_cells['cell_id'] = train_cell_lst
    hist_cells['excution_start'] = pd.to_datetime(date_list[0])
    hist_cells['model_type'] = config['model_type']
    hist_cells['model_seq'] = seq_

    return hist, hist_cells


"""
====================================================================================
학습용 데이터 처리 함수
====================================================================================
"""

def split_train_val(df, val_ratio=0.2, module_col='enb_cell_id', prb_col='prb_usage_rate', n_bins=10):

    df = df.copy()
    df[prb_col] = pd.to_numeric(df[prb_col], errors='coerce')
    df = df.dropna(subset=[prb_col])

    # 1. 모듈별 평균 PRB 계산
    module_prb = df.groupby(module_col)[prb_col].mean()

    # 2. bin 구간 생성
    bins = np.linspace(0, 100, n_bins + 1)
    module_bins = np.digitize(module_prb, bins) - 1

    train_modules = []
    val_modules = []

    # 3. bin별로 모듈 나눔
    for b in range(n_bins):
        mod_ids = module_prb.index[module_bins == b]
        mod_ids = np.array(mod_ids)
        np.random.shuffle(mod_ids)

        val_size = int(len(mod_ids) * val_ratio)
        val_modules.extend(mod_ids[:val_size])
        train_modules.extend(mod_ids[val_size:])

    # 4. 원본 df에서 모듈 기반으로 분할
    train_df = df[df[module_col].isin(train_modules)].reset_index(drop=True)
    val_df = df[df[module_col].isin(val_modules)].reset_index(drop=True)
    
    return train_df, val_df




    
def prepare_mini_batch_data(df, config, n_bins=10, debug=True):
    sequence_length = config['sequence_length']
    feature_cols = config['feature_col']

    if int(df.groupby('enb_cell_id').size().max()) <= sequence_length:
        config['sequence_length'] = int(df.groupby('enb_cell_id').size().max()) - 1
        sequence_length = config['sequence_length']

    X_seq, y_seq, y_lag1_seq, module_ids = [], [], [], []

    for mod_id, group in df.groupby('enb_cell_id', sort=False):
        group = group.sort_values('window_end')
        features = group[feature_cols].to_numpy()
        targets = group['prb_usage_rate'].to_numpy()

        for i in range(len(features) - sequence_length):
            x = np.zeros((sequence_length, features.shape[1]), dtype=np.float32)
            x[:, 0] = features[i:i + sequence_length, 0].astype(np.int32)
            x[:, 1:] = features[i:i + sequence_length, 1:].astype(np.float32)

            y_t = np.float32(targets[i + sequence_length])        # y(t)
            y_lag1 = np.float32(targets[i + sequence_length - 1]) # y(t-1)

            X_seq.append(x)
            y_seq.append(y_t)
            y_lag1_seq.append(y_lag1)
            module_ids.append(mod_id)

    X_seq = np.array(X_seq, dtype=np.float32)
    y_seq = np.log1p(np.array(y_seq, dtype=np.float32))
    y_lag1_seq = np.log1p(np.array(y_lag1_seq, dtype=np.float32))
    module_ids = np.array(module_ids)

    print(f"[DEBUG] 전체 시퀀스 수: {len(X_seq)}")

    module_avg_prb = df.groupby("enb_cell_id")["prb_usage_rate"].mean()
    bins = np.linspace(np.log1p(0), np.log1p(100), n_bins + 1)
    module_avg_bin = np.digitize(np.log1p(module_avg_prb), bins) - 1

    module_bin_groups = {f"group_{b}": set() for b in range(n_bins)}
    for mod_id, b in zip(module_avg_prb.index, module_avg_bin):
        if 0 <= b < n_bins:
            module_bin_groups[f"group_{b}"].add(mod_id)

    return X_seq, y_seq, y_lag1_seq, module_ids, bins, module_bin_groups



    
def create_mini_batches(config, X_seq, y_seq, y_lag1_seq, module_ids, bins, module_bin_groups, mode = 'train', n_bins=None, epochs = 0, debug=True):

    batch_size = config['batch_size_for_minibatch']
    n_samples_per_bin = config['interval_cell_sample']
    bin_weights = config.get('bin_sampling_weights')
    total_sample_n = config.get('total_sample_n', 30000)
    
    # ---------------------------------------------------------
    # 2. Y값 기반 Binning (시퀀스 타겟 기준)
    # ---------------------------------------------------------   
    bin_indices = np.digitize(y_seq, bins) - 1

    # ---------------------------------------------------------
    # 3. 샘플링
    # ---------------------------------------------------------
    selected_idx = []
    train_bin_to_ids = {}

    if bin_weights is None:
        bin_weights = np.ones(n_bins) / n_bins
    else:
        bin_weights = np.array(bin_weights)
        bin_weights = bin_weights / bin_weights.sum()


    for b in range(n_bins):
        indices = np.where(bin_indices == b)[0]
        if len(indices) == 0:
            continue
         
        desired_n = int(total_sample_n * bin_weights[b])
        replace_flag = len(indices) < desired_n
        
        
        if replace_flag:
            print(f"[WARN] group_{b}: 시퀀스 부족 (요청: {desired_n}, 실제: {len(indices)}). 중복 샘플링 수행")
        
        
        chosen = np.random.choice(indices, size=desired_n, replace=replace_flag)
        selected_idx.extend(chosen)
        train_bin_to_ids[f"group_{b}"] = set(module_ids[chosen])

        
    selected_idx = np.array(selected_idx)
    np.random.shuffle(selected_idx)
        

    if len(selected_idx) == 0:
        print("[WARNING] 선택된 샘플이 없습니다! 시퀀스 길이, PRB 분포, n_bins 확인 필요")

    
    if debug and mode == 'Train' and epochs == 0:
        print(f"[DEBUG] selected_idx 시퀀스 길이: {len(selected_idx)}")
        print(f"[DEBUG] 생성된 배치 수: {int(np.ceil(len(selected_idx) / batch_size))}")
        print("[DEBUG] selected_idx 그룹별 시퀀스 수:")
        for b in range(n_bins):
            count = (bin_indices[selected_idx] == b).sum()
            print(f" group_{b}: {count} samples")
        print("[DEBUG] 그룹별 사용된 모듈 ID 수")
        for b in range(n_bins):
            group_key = f"group_{b}"
            count = len(train_bin_to_ids.get(group_key, []))
            print(f"{group_key}: {count} modules")


    # ---------------------------------------------------------
    # 4. 배치 생성
    #    마지막 배치에서:
    #    - train_bin_to_ids (학습에 사용된 모듈)
    #    - module_bin_groups (전체 모듈 평균 PRB 기준 bin 분포)
    # ---------------------------------------------------------
    num_batches = int(np.ceil(len(selected_idx) / batch_size))
    # if mode == 'Train':
    #     print(f"[DEBUG] 학습용 데이터 생성된 배치 수: {num_batches}")
    # else:
    #     print(f"[DEBUG] 검증용 데이터 생성된 배치 수: {num_batches}")
        

    for batch_idx in range(num_batches):
        start = batch_idx * batch_size
        end = start + batch_size
        idx = selected_idx[start:end]

        meta = None
        if batch_idx == num_batches - 1:
            # 마지막 배치에서 전체 bin grouping 정보도 함께 반환
            meta = {
                "train_bin_to_ids": train_bin_to_ids,
                "module_bin_groups": module_bin_groups
                }
                
            yield X_seq[idx], y_seq[idx], y_lag1_seq[idx], meta



def weighted_huber_loss(preds, targets, weights=None, delta=1.0):
    """
    가중치를 적용한 Huber (SmoothL1) 손실 계산
    preds, targets, weights: 어떤 shape든 들어와도 1D로 flatten 해서 사용
    """
    # 1) 1차원으로 정리
    preds = preds.view(-1)
    targets = targets.view(-1)

    # 2) 길이 다르면 공통 최소 길이에 맞춰 잘라서 사용 (shape mismatch 방지)
    n = min(preds.numel(), targets.numel())
    preds = preds[:n]
    targets = targets[:n]

    if weights is not None:
        weights = weights.view(-1)[:n]

    # 3) Huber 계산
    abs_error = torch.abs(preds - targets)

    delta_t = torch.tensor(delta, device=abs_error.device, dtype=abs_error.dtype)
    quadratic = torch.minimum(abs_error, delta_t)
    linear = abs_error - quadratic

    loss = 0.5 * quadratic ** 2 + delta_t * linear

    if weights is not None:
        loss = loss * weights

    return loss.mean()



def collect_batches_with_bins(generator_func):
    batches = []
    try:
        while True:
            batch = next(generator_func)
            batches.append(batch)
    except StopIteration as e:
        bin_to_ids = e.value
    return batches, bin_to_ids




"""
====================================================================================
예측용 데이터 처리 함수
====================================================================================
"""
# 로컬 폴더에서 'config.pbtxt'파일의 sequence 읽기
def extract_sequence_length_from_pbtxt(filepath):
    with open(filepath, 'r') as f:
        lines = f.readlines()

    dims_line = None
    for line in lines:
        if 'dims:' in line and 'input' in ''.join(lines[lines.index(line)-5:lines.index(line)]):  # input block 내부인지 확인
            dims_line = line.strip()
            break

    if dims_line:
        # 정수 리스트 추출
        dims = re.findall(r'-?\d+', dims_line)
        dims = list(map(int, dims))
        if len(dims) >= 2:
            sequence_length = dims[1]
            return sequence_length
        else:
            raise ValueError("dims 항목이 예상보다 짧습니다.")
    else:
        raise ValueError("input 섹션 내 dims 항목을 찾을 수 없습니다.")



from collections import defaultdict
import gc


def _to_utc_naive(ts):
    """Timestamp/str → UTC 기준 naive Timestamp 로 통일"""
    t = pd.to_datetime(ts, errors="coerce", utc=True)
    
    if hasattr(t, "dt"):
        return t.dt.tz_convert("UTC").dt.tz_localize(None)

    tz = getattr(t, "tzinfo", None)
    if tz is not None:
        t = t.tz_convert("UTC").tz_localize(None)
    return t




def _query_hist_for_cells_in_chunks(
    client,
    hist_table,
    cell_col,
    time_col,
    min_hist_str,
    max_hist_str,
    cells,
):
    """
    ai.cell_usage_hist_5m 용: cell_id 리스트 조회
    """
    n = len(cells)
    if n == 0:
        return pd.DataFrame(columns=["enb_cell_id", "window_end", "prb_usage_rate"])
    q = f"""
        SELECT
            {cell_col} AS enb_cell_id,
            {time_col} AS window_end,
            prb_usage_rate
        FROM {hist_table}
        WHERE {time_col} BETWEEN toDateTime('{min_hist_str}')
                             AND toDateTime('{max_hist_str}')
    """
    # total_df = client.query_df(q)
    
    result = client.query_arrow(q)
    total_df = result.to_pandas()
    
    
    if len(total_df) > 0:
        total_df["enb_cell_id"] = total_df["enb_cell_id"].astype(str)
        return total_df[total_df['enb_cell_id'].isin(set(cells))]
    else:
        return pd.DataFrame(columns=["enb_cell_id", "window_end", "prb_usage_rate"])
    
    
def _query_pred_for_cells_in_chunks(
    client,
    pred_table,
    cell_col,
    time_col,
    min_pred_str,
    max_pred_str,
    cells,
):
    """
    ai.t_cell_prb_usage_predicted 용: cell_id 리스트 조회
    """
    n = len(cells)
    if n == 0:
        return pd.DataFrame(columns=["enb_cell_id", "window_end", "prb_usage_predicted"])

    q = f"""
        SELECT
            {cell_col} AS enb_cell_id,
            {time_col} AS window_end,
            prb_usage_predicted
        FROM {pred_table}
        WHERE {time_col} BETWEEN toDateTime('{min_pred_str}')
                             AND toDateTime('{max_pred_str}')
    """

    result = client.query_arrow(q)
    # db 쿼리시 메모리와 트래픽 증가 현상이 발생하여 sleep 추가함
    # time.sleep(4)

    total_df = result.to_pandas()
    
    if len(total_df) > 0:
        total_df["enb_cell_id"] = total_df["enb_cell_id"].astype(str)
        return total_df[total_df['enb_cell_id'].isin(set(cells))]
    else:
        return pd.DataFrame(columns=["enb_cell_id", "window_end", "prb_usage_predicted"])


def _floor_5min(ts: pd.Timestamp) -> pd.Timestamp:
    return ts.floor("5min")


# def build_y_lag1_map(test_df, config, client):
#     # 실제 PRB(hist)
#     hist_table = "ai.cell_usage_hist_5m"
#     hist_cell_col = "enb_cell_id"
#     hist_time_col = "window_end"
#     delay_min = int(config.get("delay_steps", 40))

#     print(time.time())
#     # 예측 PRB(pred)
#     pred_table = config.get("result_table_name", "ai.t_cell_prb_usage_predicted")
#     pred_cell_col = "cell_id"
#     pred_time_col = "window_end"
#     print(time.time())
#     # 1) keys: 셀별 target_time(최신 window_end)
#     keys = (
#         test_df.groupby("enb_cell_id", sort=False)["window_end"]
#         .max()
#         .reset_index()
#         .rename(columns={"window_end": "target_time"})
#     )
#     print(time.time())
#     # UTC naive로 통일 (사용 중인 헬퍼 그대로)
#     keys["t_utc"] = pd.to_datetime(keys["target_time"].apply(_to_utc_naive), errors="coerce")
#     keys = keys.dropna(subset=["t_utc"]).copy()
#     print(time.time())
#     keys["t_floor"] = keys["t_utc"].dt.floor("5min")
#     keys["y_time"]  = keys["t_floor"] - pd.Timedelta(minutes=delay_min)
#     print(time.time())
#     # pred fallback은 "t_floor-5min" 정확매칭으로 (가장 빠름)
#     keys["cell_id"] = keys["enb_cell_id"].astype(str)
#     keys["want_time"] = keys["t_floor"] - pd.Timedelta(minutes=5)
#     print(time.time())
#     y_map = {}

#     # 2) hist에서 벡터라이즈로 한 번에 조회
#     min_hist_t = keys["y_time"].min()
#     max_hist_t = keys["y_time"].max()
#     if pd.isna(min_hist_t) or pd.isna(max_hist_t):
#         return y_map
#     print(time.time())
#     min_hist_str = min_hist_t.strftime("%Y-%m-%d %H:%M:%S")
#     max_hist_str = max_hist_t.strftime("%Y-%m-%d %H:%M:%S")
#     cells = keys["enb_cell_id"].unique().tolist()
#     print(time.time())
#     hist_df = _query_hist_for_cells_in_chunks(
#         client, hist_table, hist_cell_col, hist_time_col,
#         min_hist_str, max_hist_str, cells, chunk_size=100000
#     )
#     print(time.time())
#     hist_vals = pd.Series(dtype=float, index=keys.index)  # keys와 동일 인덱스
#     if hist_df is not None and not hist_df.empty:
#         hist_df = hist_df[[hist_cell_col, hist_time_col, "prb_usage_rate"]].copy()
#         hist_df[hist_time_col] = pd.to_datetime(hist_df[hist_time_col].apply(_to_utc_naive), errors="coerce")
#         hist_df = hist_df.dropna(subset=[hist_time_col])

#         # (enb_cell_id, window_end) -> prb_usage_rate
#         hist_df.set_index([hist_cell_col, hist_time_col], inplace=True)

#         mi_hist = pd.MultiIndex.from_frame(keys[[hist_cell_col, "y_time"]])
#         hist_vals = hist_df["prb_usage_rate"].reindex(mi_hist).reset_index(drop=True)
#     print(time.time())
#     # hist로 채워진 것 dict 반영
#     ok_hist = hist_vals.notna().to_numpy()
#     if ok_hist.any():
#         sub = keys.loc[ok_hist, ["cell_id", "t_utc"]]
#         vals = hist_vals.loc[ok_hist].astype(float).to_numpy()
#         for (cid, tgt), v in zip(sub.to_numpy(), vals):
#             y_map[(cid, tgt)] = float(v)
#     print(time.time())
#     # 3) hist에서 못 찾은 것만 pred에서 "정확매칭"으로 조회
#     miss_idx = keys.index[~ok_hist]
#     if len(miss_idx) == 0:
#         return y_map
#     print(time.time())
#     miss = keys.loc[miss_idx, ["cell_id", "t_utc", "want_time"]].copy()

#     min_pred_t = miss["want_time"].min()
#     max_pred_t = miss["want_time"].max()
#     if pd.isna(min_pred_t) or pd.isna(max_pred_t):
#         return y_map
#     print(time.time())
#     # want_time 범위만 딱 조회 (기존처럼 약간 버퍼 주고 싶으면 +-5~10분만)
#     min_pred_str = (min_pred_t - pd.Timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
#     max_pred_str = (max_pred_t + pd.Timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
#     cells_pred = miss["cell_id"].unique().tolist()

#     pred_df = _query_pred_for_cells_in_chunks(
#         client, pred_table, pred_cell_col, pred_time_col,
#         min_pred_str, max_pred_str, cells_pred, chunk_size=100000
#     )
#     if pred_df is None or pred_df.empty:
#         return y_map
#     print(time.time())
#     pred_df = pred_df[[pred_cell_col, pred_time_col, "prb_usage_predicted"]]
#     print('time00:', time.time())
#     pred_df[pred_cell_col] = pred_df[pred_cell_col].astype(str)
#     print('time01:', time.time())
#     pred_df[pred_time_col] = pd.to_datetime(pred_df[pred_time_col], errors="coerce")
#     print('time02:', time.time())
#     pred_df = pred_df.dropna(subset=[pred_time_col])
#     print('time03:', time.time())
#     # 5분 그리드로 맞춰서 정확매칭
#     pred_df["t_floor"] = pred_df[pred_time_col].dt.floor("5min")
#     print('time0:', time.time())
#     # (cell_id, t_floor) -> prb_usage_predicted (중복 있으면 마지막 값 사용)
#     pred_df.sort_values([pred_cell_col, "t_floor"], inplace=True)
#     pred_last = pred_df.drop_duplicates([pred_cell_col, "t_floor"], keep="last")
#     pred_last.set_index([pred_cell_col, "t_floor"], inplace=True)
#     print('time1:', time.time())
#     mi_pred = pd.MultiIndex.from_frame(miss[["cell_id", "want_time"]].rename(columns={"want_time": "t_floor"}))
#     pred_vals = pred_last["prb_usage_predicted"].reindex(mi_pred)

#     print('time2:', time.time())
#     ok_pred = pred_vals.notna().to_numpy()
#     if ok_pred.any():
#         sub = miss.loc[ok_pred, ["cell_id", "t_utc"]]
#         vals = pred_vals.loc[ok_pred].astype(float).to_numpy()
#         print('time3:', time.time())
#         for (cid, tgt), v in zip(sub.to_numpy(), vals):
#             y_map[(cid, tgt)] = float(v)

#     print('time4:', time.time())
#     return y_map


def build_y_lag1_map(test_df, config, client):
    # 실제 PRB(hist)
    hist_table = "ai.cell_usage_hist_5m"
    hist_cell_col = "enb_cell_id"
    hist_time_col = "window_end"
    delay_min = int(config.get("delay_steps", 40))

    # 예측 PRB(pred)
    pred_table = config.get("result_table_name", "ai.t_cell_prb_usage_predicted")
    pred_cell_col = "cell_id"
    pred_time_col = "window_end"

    # 1) keys: 셀별 target_time(최신 window_end)
    keys = (
        test_df.groupby("enb_cell_id", sort=False)["window_end"]
        .max()
        .reset_index()
        .rename(columns={"window_end": "target_time"})
    )

    # UTC naive로 통일
    keys["t_utc"] = pd.to_datetime(keys["target_time"].apply(_to_utc_naive), errors="coerce")
    keys = keys.dropna(subset=["t_utc"]).copy()

    keys["t_floor"] = keys["t_utc"].dt.floor("5min")
    keys["y_time"]  = keys["t_floor"] - pd.Timedelta(minutes=delay_min)

    # pred fallback은 "t_floor-5min" 정확매칭
    keys["cell_id"] = keys["enb_cell_id"].astype(str)
    keys["want_time"] = keys["t_floor"] - pd.Timedelta(minutes=5)

    y_map = {}

    # 2) hist에서 벡터라이즈 조회
    min_hist_t = keys["y_time"].min()
    max_hist_t = keys["y_time"].max()
    if pd.isna(min_hist_t) or pd.isna(max_hist_t):
        return y_map

    min_hist_str = min_hist_t.strftime("%Y-%m-%d %H:%M:%S")
    max_hist_str = max_hist_t.strftime("%Y-%m-%d %H:%M:%S")
    cells = keys["enb_cell_id"].unique().tolist()

    hist_df = _query_hist_for_cells_in_chunks(
        client, hist_table, hist_cell_col, hist_time_col,
        min_hist_str, max_hist_str, cells
    )

    hist_vals = pd.Series(dtype=float, index=keys.index)  # keys와 동일 인덱스
    if hist_df is not None and not hist_df.empty:
        hist_df = hist_df[[hist_cell_col, hist_time_col, "prb_usage_rate"]].copy()
        hist_df[hist_time_col] = pd.to_datetime(hist_df[hist_time_col].apply(_to_utc_naive), errors="coerce")
        hist_df = hist_df.dropna(subset=[hist_time_col])

        # (enb_cell_id, window_end) -> prb_usage_rate
        hist_df.set_index([hist_cell_col, hist_time_col], inplace=True)

        mi_hist = pd.MultiIndex.from_frame(keys[[hist_cell_col, "y_time"]])
        hist_vals = hist_df["prb_usage_rate"].reindex(mi_hist).reset_index(drop=True)

    # hist로 채워진 것 dict 반영
    ok_hist = hist_vals.notna().to_numpy()
    if ok_hist.any():
        sub = keys.loc[ok_hist, ["cell_id", "t_floor"]]
        vals = hist_vals.loc[ok_hist].astype(float).to_numpy()
        for (cid, tgt), v in zip(sub.to_numpy(), vals):
            y_map[(cid, tgt)] = float(v)

    # 3) hist에서 못 찾은 것만 pred에서 매칭 후 조회
    miss_idx = keys.index[~ok_hist]
    if len(miss_idx) == 0:
        return y_map

    miss = keys.loc[miss_idx, ["cell_id", "t_floor", "want_time"]].copy()

    min_pred_t = miss["want_time"].min()
    max_pred_t = miss["want_time"].max()
    if pd.isna(min_pred_t) or pd.isna(max_pred_t):
        return y_map

    # want_time 범위만 조회
    min_pred_str = (min_pred_t - pd.Timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
    max_pred_str = (max_pred_t + pd.Timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
    cells_pred = miss["cell_id"].unique().tolist()

    pred_df = _query_pred_for_cells_in_chunks(
        client, pred_table, pred_cell_col, pred_time_col,
        min_pred_str, max_pred_str, cells_pred
    )
    if pred_df is None or pred_df.empty:
        return y_map

    pred_df = pred_df[["enb_cell_id", pred_time_col, "prb_usage_predicted"]]
    pred_df["enb_cell_id"] = pred_df["enb_cell_id"].astype(str)
    
    # pred_df[pred_time_col] = pd.to_datetime(pred_df[pred_time_col], errors="coerce")
    pred_df[pred_time_col] = (pd.to_datetime(pred_df[pred_time_col], unit="s", utc=True).dt.tz_convert(None).dt.floor("5min"))
    pred_df = pred_df.dropna(subset=[pred_time_col])
    
    print(f"pred_df: {pred_df}")

    # 5분 그리드로 맞춰서 정확매칭
    pred_df["t_floor"] = pred_df[pred_time_col].dt.floor("5min")

    # (cell_id, t_floor) -> prb_usage_predicted (중복 있으면 마지막 값 사용)
    pred_df.sort_values(["enb_cell_id", "t_floor"], inplace=True)
    pred_last = pred_df.drop_duplicates(["enb_cell_id", "t_floor"], keep="last")
    pred_last.set_index(["enb_cell_id", "t_floor"], inplace=True)
    mi_pred = pd.MultiIndex.from_frame(miss[["cell_id", "want_time"]].rename(columns={"want_time": "t_floor"}))
    pred_vals = pred_last["prb_usage_predicted"].reindex(mi_pred)

    ok_pred = pred_vals.notna().to_numpy()
    if ok_pred.any():
        sub = miss.loc[ok_pred, ["cell_id", "t_floor"]]
        vals = pred_vals.loc[ok_pred].astype(float).to_numpy()
        for (cid, tgt), v in zip(sub.to_numpy(), vals):
            y_map[(cid, tgt)] = float(v)
            

            
    return y_map



def _query_hist_by_time_range(client, table, time_col, min_t_str, max_t_str):
    q = f"""
    SELECT enb_cell_id, {time_col} AS window_end, prb_usage_rate
    FROM {table}
    WHERE {time_col} >= toDateTime('{min_t_str}')
      AND {time_col} <= toDateTime('{max_t_str}')
    """
    return client.query_df(q)

def _query_pred_by_time_range(client, table, time_col, min_t_str, max_t_str):
    q = f"""
    SELECT cell_id, {time_col} AS window_end, prb_usage_predicted
    FROM {table}
    WHERE {time_col} >= toDateTime('{min_t_str}')
      AND {time_col} <= toDateTime('{max_t_str}')
    """
    return client.query_df(q)


# def build_y_lag1_map(test_df, config, client):
#     hist_table = "ai.cell_usage_hist_5m"
#     hist_cell_col = "enb_cell_id"
#     hist_time_col = "window_end"
#     delay_min = int(config.get("delay_steps", 40))

#     pred_table = config.get("result_table_name", "ai.t_cell_prb_usage_predicted")
#     pred_cell_col = "cell_id"
#     pred_time_col = "window_end"

#     keys = (
#         test_df.groupby("enb_cell_id", sort=False)["window_end"]
#         .max()
#         .reset_index()
#         .rename(columns={"window_end": "target_time"})
#     )

#     keys["t_utc"] = pd.to_datetime(keys["target_time"].apply(_to_utc_naive), errors="coerce")
#     keys = keys.dropna(subset=["t_utc"]).copy()

#     keys["t_floor"] = keys["t_utc"].dt.floor("5min")
#     keys["y_time"]  = keys["t_floor"] - pd.Timedelta(minutes=delay_min)

#     keys["cell_id"] = keys["enb_cell_id"].astype(str)
#     keys["want_time"] = keys["t_floor"] - pd.Timedelta(minutes=5)

#     y_map = {}

#     min_hist_t = keys["y_time"].min()
#     max_hist_t = keys["y_time"].max()
#     if pd.isna(min_hist_t) or pd.isna(max_hist_t):
#         return y_map

#     min_hist_str = min_hist_t.strftime("%Y-%m-%d %H:%M:%S")
#     max_hist_str = max_hist_t.strftime("%Y-%m-%d %H:%M:%S")
#     cells = keys["enb_cell_id"].unique().tolist()

#     # 셀이 너무 많으면 IN 기반 청크쿼리보다 "시간 범위 단일쿼리"가 빠른 경우가 많음
#     if len(cells) >= 50000:
#         hist_df = _query_hist_by_time_range(client, hist_table, hist_time_col, min_hist_str, max_hist_str)
#     else:
#         hist_df = _query_hist_for_cells_in_chunks(
#             client, hist_table, hist_cell_col, hist_time_col,
#             min_hist_str, max_hist_str, cells
#         )

#     hist_vals = pd.Series(np.nan, index=keys.index, dtype=float)

#     if hist_df is not None and not hist_df.empty:
#         hist_df = hist_df[[hist_cell_col, hist_time_col, "prb_usage_rate"]].copy()
#         hist_df[hist_time_col] = pd.to_datetime(hist_df[hist_time_col].apply(_to_utc_naive), errors="coerce")
#         hist_df = hist_df.dropna(subset=[hist_time_col])

#         hist_df.set_index([hist_cell_col, hist_time_col], inplace=True)
#         mi_hist = pd.MultiIndex.from_frame(keys[[hist_cell_col, "y_time"]])
#         hist_vals = hist_df["prb_usage_rate"].reindex(mi_hist).to_numpy()

#     ok_hist = ~pd.isna(hist_vals)
#     if ok_hist.any():
#         sub = keys.loc[ok_hist, ["cell_id", "t_utc"]]
#         vals = np.asarray(hist_vals, dtype=float)[ok_hist]

#         # for-loop 제거: 한번에 dict 생성
#         y_map.update(dict(zip(zip(sub["cell_id"].to_numpy(), sub["t_utc"].to_numpy()), vals)))

#     miss_mask = ~ok_hist
#     if not miss_mask.any():
#         return y_map

#     miss = keys.loc[miss_mask, ["cell_id", "t_utc", "want_time"]].copy()

#     min_pred_t = miss["want_time"].min()
#     max_pred_t = miss["want_time"].max()
#     if pd.isna(min_pred_t) or pd.isna(max_pred_t):
#         return y_map

#     min_pred_str = (min_pred_t - pd.Timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
#     max_pred_str = (max_pred_t + pd.Timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
#     cells_pred = miss["cell_id"].unique().tolist()

#     if len(cells_pred) >= 50000:
#         pred_df = _query_pred_by_time_range(client, pred_table, pred_time_col, min_pred_str, max_pred_str)
#     else:
#         pred_df = _query_pred_for_cells_in_chunks(
#             client, pred_table, pred_cell_col, pred_time_col,
#             min_pred_str, max_pred_str, cells_pred
#         )

#     if pred_df is None or pred_df.empty:
#         return y_map

#     pred_df = pred_df[[pred_cell_col, pred_time_col, "prb_usage_predicted"]].copy()
#     pred_df[pred_cell_col] = pred_df[pred_cell_col].astype(str)
#     pred_df[pred_time_col] = pd.to_datetime(pred_df[pred_time_col].apply(_to_utc_naive), errors="coerce")
#     pred_df = pred_df.dropna(subset=[pred_time_col])

#     pred_df["t_floor"] = pred_df[pred_time_col].dt.floor("5min")
#     pred_df.sort_values([pred_cell_col, "t_floor"], inplace=True)
#     pred_last = pred_df.drop_duplicates([pred_cell_col, "t_floor"], keep="last")
#     pred_last.set_index([pred_cell_col, "t_floor"], inplace=True)

#     mi_pred = pd.MultiIndex.from_frame(
#         miss[["cell_id", "want_time"]].rename(columns={"want_time": "t_floor"})
#     )
#     pred_vals = pred_last["prb_usage_predicted"].reindex(mi_pred).to_numpy()

#     ok_pred = ~pd.isna(pred_vals)
#     if ok_pred.any():
#         sub = miss.loc[ok_pred, ["cell_id", "t_utc"]]
#         vals = np.asarray(pred_vals, dtype=float)[ok_pred]
#         y_map.update(dict(zip(zip(sub["cell_id"].to_numpy(), sub["t_utc"].to_numpy()), vals)))

#     return y_map





# def build_y_lag1_map(test_df, config, client):
    
#     # 실제 PRB 테이블
#     hist_table = "ai.cell_usage_hist_5m"
#     hist_cell_col = "enb_cell_id"
#     hist_time_col = "window_end"
#     delay_min = int(config.get("delay_steps", 40))
    
#     # 추론 PRB 테이블
#     pred_table = config.get("result_table_name", "ai.t_cell_prb_usage_predicted")
#     pred_cell_col = "cell_id"
#     pred_time_col = "window_end"  # 원래 코드 버그 수정

#     # 1) 각 셀의 target_time = test_df의 최신 window_end
#     keys = (
#         test_df.groupby("enb_cell_id", sort=False)["window_end"]
#         .max()
#         .reset_index()
#         .rename(columns={"window_end": "target_time"})
#     )
    
#     keys["cell_id"] = keys["enb_cell_id"].astype(str)
    
#     # timezone/utc naive 통일
#     keys["t_utc"] = keys["target_time"].apply(_to_utc_naive)
#     keys["t_floor"] = keys["t_utc"].dt.floor("5min")
#     keys["y_time"] = keys["t_floor"] - pd.Timedelta(minutes=delay_min)

#     y_map = {}

#     # 2) hist에서 먼저 채우기 (가능한 만큼)
#     min_hist_t = keys["y_time"].min()
#     max_hist_t = keys["y_time"].max()


#     min_hist_str = min_hist_t.strftime("%Y-%m-%d %H:%M:%S")
#     max_hist_str = max_hist_t.strftime("%Y-%m-%d %H:%M:%S")
#     cells = keys["enb_cell_id"].unique().tolist()

#     hist_df = _query_hist_for_cells_in_chunks(
#         client, hist_table, hist_cell_col, hist_time_col,
#         min_hist_str, max_hist_str, cells, chunk_size=800
#     )

#     if not hist_df.empty:
#         hist_df["window_end"] = hist_df["window_end"].apply(_to_utc_naive)
#         hist_df.set_index(["enb_cell_id", "window_end"], inplace=True)

#         for _, r in keys.iterrows():
#             cid = r["enb_cell_id"]
#             tgt = r["t_utc"]
#             y_time = r["y_time"]
#             try:
#                 y = float(hist_df.loc[(cid, y_time), "prb_usage_rate"])
#                 y_map[(cid, tgt)] = y   # key는 항상 (cid, t_utc)로 통일
#             except KeyError:
#                 pass

#     # 3) hist에서 못 찾은 것만 pred로 fallback
#     miss = keys[~keys.apply(lambda r: (r["enb_cell_id"], r["t_utc"]) in y_map, axis=1)]
#     if not miss.empty:
#         # pred는 +/- 5분 정도 넓혀서 조회
#         min_pred_t = miss["t_floor"].min() - pd.Timedelta(minutes=10)
#         max_pred_t = miss["t_floor"].max() + pd.Timedelta(minutes=10)
#         min_pred_str = min_pred_t.strftime("%Y-%m-%d %H:%M:%S")
#         max_pred_str = max_pred_t.strftime("%Y-%m-%d %H:%M:%S")
#         # cells_pred = miss["enb_cell_id"].unique().tolist()
#         cells_pred = miss["cell_id"].unique().tolist()

#         pred_df = _query_pred_for_cells_in_chunks(
#             client, pred_table, pred_cell_col, pred_time_col,
#             min_pred_str, max_pred_str, cells_pred, chunk_size=800
#         )

#         if not pred_df.empty:
#             pred_df[pred_time_col] = pred_df[pred_time_col].apply(_to_utc_naive)
#             pred_df.sort_values([pred_cell_col, pred_time_col], inplace=True)

#             for cid, g in pred_df.groupby(pred_cell_col):
#                 times = g[pred_time_col].to_numpy()
#                 vals = g["prb_usage_predicted"].to_numpy()

#                 # sub = miss[miss["enb_cell_id"] == cid]
#                 sub = miss[miss["cell_id"] == cid]
#                 for _, r in sub.iterrows():
#                     tgt = r["t_utc"]
#                     # lag 기준: 직전 5분 격자 시점(t_floor - 5min)을 가장 가까운 pred로
#                     want = r["t_floor"] - pd.Timedelta(minutes=5)

#                     if len(times) == 0:
#                         continue
#                     idx = int(np.argmin(np.abs(times - want.to_datetime64())))
#                     y_map[(cid, tgt)] = float(vals[idx])

#     return y_map



# def create_mini_batches_predict(test_df, config):
#     seq_len = config["sequence_length"]
#     feature_cols = config["feature_col"]

#     X_list = []
#     y_lag1_list = []
#     used_cell_ids = []

#     skipped_y_lag1 = 0

#     # ClickHouse 클라이언트 생성
#     client = clickhouse_connect.get_client(
#     host=config['db_host'],
#     port=config['db_port'],
#     username=config['db_username'],
#     password=config['db_password'],
#     database=config['db_database'],
#     connect_timeout=3000000,  # 연결 타임아웃 (초)
#     send_receive_timeout=3000000  # 요청/응답 타임아웃 (초)

#     )
    
#     start = time.time()
    
#     y_map = build_y_lag1_map(test_df, config, client)
    
#     end = time.time()
#     print(f"build_y_lag1_map 처리 시간 : {end - start:.2f}초")

    
#     test_df = test_df.sort_values(["enb_cell_id", "window_end"])
    
#     enb_arr = test_df["enb_cell_id"].to_numpy()
#     feat_arr = test_df[feature_cols].to_numpy(dtype=np.float32)
    
#     chg = np.r_[True, enb_arr[1:] != enb_arr[:-1]]
#     starts = np.flatnonzero(chg)
#     ends = np.r_[starts[1:], len(enb_arr)]
    
#     start = time.time()
#     for s, e in zip(starts, ends):
#         enb_id = enb_arr[s]
#         feat = feat_arr[s:e]
#         avail_len = feat.shape[0]
        
#         if avail_len == 0:
#             continue
        
#         use_len = min(seq_len, avail_len)
        
#         # y_map과 동일한 시간 축으로 맞추기 
#         # target_time_raw = test_df.loc[e - 1, "window_end"]
#         target_time_raw = test_df.iloc[e - 1]["window_end"]
#         target_time = _to_utc_naive(target_time_raw)
        
#         y_lag1_raw = y_map.get((enb_id, target_time))
#         if y_lag1_raw is None:
#             skipped_y_lag1 += 1
#             continue
            
#         # if np.random.rand() < 0.0001:
#         #     print("sample y_lag1_raw: ", y_lag1_raw, "scaler: ", config.get("scaler"))
            

#         x_window = np.zeros((seq_len, feat.shape[1]), dtype=np.float32)
#         x_window[-use_len:, 0] = feat[-use_len:, 0].astype(np.int32)
#         x_window[-use_len:, 1:] = feat[-use_len:, 1:].astype(np.float32)

#         X_list.append(x_window)
#         y_lag1_list.append(np.log1p(float(y_lag1_raw)))
#         used_cell_ids.append(enb_id)
        
#     end = time.time()
#     print(f"y_lag1_list 처리 시간 : {end - start:.2f}초")
        
#     if len(X_list) == 0:
#         print(f"[WARN] predict sequence 생성 0건 (y_lag1 조회 실패: {skipped_y_lag1})")
#         X_seq = np.empty((0, seq_len, feat_arr.shape[1]), dtype=np.float32)
#         y_lag1_seq = np.empty((0, 1), dtype=np.float32)
#         used_cell_ids = np.array([], dtype=enb_arr.dtype)
#         return X_seq, y_lag1_seq, used_cell_ids
        

#     X_seq = np.stack(X_list, axis=0)
#     y_lag1_seq = np.array(y_lag1_list, dtype=np.float32).reshape(-1, 1)
#     used_cell_ids = np.array(used_cell_ids)
    
#     print("y_lag1_seq min/max: ", y_lag1_seq.min(), y_lag1_seq.max())
    
#     print("[INFO] Predict sequence 생성 결과")
#     print(f"  - 사용 시퀀스 수          : {len(X_seq)}")
#     print(f"  - y_lag1 미조회 제외      : {skipped_y_lag1}")

#     return X_seq, y_lag1_seq, used_cell_ids



from collections import defaultdict

def create_mini_batches_predict(test_df, config):
    seq_len = int(config["sequence_length"])
    feature_cols = config["feature_col"]

    X_list = []
    y_lag1_list = []
    used_cell_ids = []

    skipped_short = 0
    skipped_nan_feat = 0
    skipped_y_lag1 = 0
    skipped_type = 0
    
    # ClickHouse 클라이언트 생성
    client = clickhouse_connect.get_client(
    host=config['db_host'],
    port=config['db_port'],
    username=config['db_username'],
    password=config['db_password'],
    database=config['db_database'],
    connect_timeout=3000000,  # 연결 타임아웃 (초)
    send_receive_timeout=3000000  # 요청/응답 타임아웃 (초)

    )

    t0 = time.time()
    y_map = build_y_lag1_map(test_df, config, client)
    t1 = time.time()
    print(f"[INFO] build_y_lag1_map 처리 시간: {t1 - t0:.2f}초 / y_map size={len(y_map)}")

    test_df = test_df.sort_values(["enb_cell_id", "window_end"], kind="mergesort")

    enb_arr = test_df["enb_cell_id"].to_numpy()
    feat_arr = test_df[feature_cols].to_numpy(dtype=np.float32)
    win_arr = test_df["window_end"].to_numpy()

    # 그룹 시작/끝 인덱스
    chg = np.r_[True, enb_arr[1:] != enb_arr[:-1]]
    starts = np.flatnonzero(chg)
    ends = np.r_[starts[1:], len(enb_arr)]

    t2 = time.time()
    for s, e in zip(starts, ends):
        enb_id = str(enb_arr[s])
        avail_len = e - s

        # 길이 부족이면 제외
        if avail_len <= 0:
            skipped_short += 1
            continue

        # target_time=해당 셀의 마지막 window_end
        target_time_raw = win_arr[e - 1]
        target_time = pd.to_datetime(_to_utc_naive(target_time_raw)).floor("5min")

        # y_lag1 조회
        y_lag1_raw = y_map.get((enb_id, target_time))
        
        if y_lag1_raw is None and skipped_y_lag1 < 3: 
            print(f"[DEBUG], ({enb_id}, {target_time})")
            print(f"[DEBUG], {next(iter(y_map.keys()))}")
            
        
        if y_lag1_raw is None:
            skipped_y_lag1 += 1
            continue
            
            

        # float 변환
        try:
            y_lag1_val = float(y_lag1_raw)
        except (TypeError, ValueError):
            skipped_type += 1
            continue

        # 사용할 길이=최신 use_len개
        use_len = min(seq_len, avail_len)
        feat_tail = feat_arr[e - use_len:e]  # 최신 use_len개
        
        if np.isnan(feat_tail).any() or np.isinf(feat_tail).any():
            skipped_nan_feat += 1
            feat_tail = np.nan_to_num(feat_tail, nan=0.0, posinf=0.0, neginf=0.0)

#         # feature NaN 체크
#         if np.isnan(feat_tail).any():
#             skipped_nan_feat += 1
#             continue

        # X window 생성: 오른쪽 정렬(앞은 0-padding)
        x_window = np.zeros((seq_len, feat_arr.shape[1]), dtype=np.float32)

        # 첫 컬럼이 categorical id(정수)라면 학습과 동일하게 유지
        x_window[-use_len:, 0] = feat_tail[:, 0].astype(np.int32)

        # 나머지는 float
        if feat_arr.shape[1] > 1:
            x_window[-use_len:, 1:] = feat_tail[:, 1:].astype(np.float32)

        X_list.append(x_window)
        # y_lag1은 log1p로 맞춘다고 했던 기존 정책 유지
        y_lag1_list.append(np.log1p(y_lag1_val))
        used_cell_ids.append(enb_id)

    t3 = time.time()
    print(f"[INFO] sequence 생성 루프 처리 시간: {t3 - t2:.2f}초")

    if len(X_list) == 0:
        print(
            "[WARN] Predict sequence 생성 0건\n"
            f"  - y_lag1 미조회 제외 : {skipped_y_lag1}\n"
            f"  - feature NaN 제외   : {skipped_nan_feat}\n"
            f"  - y_lag1 타입 제외   : {skipped_type}\n"
            f"  - short 제외(기타)   : {skipped_short}\n"
        )
        # 빈 텐서 반환
        X_seq = np.empty((0, seq_len, feat_arr.shape[1]), dtype=np.float32)
        y_lag1_seq = np.empty((0, 1), dtype=np.float32)
        used_cell_ids = np.array([], dtype=enb_arr.dtype)
        return X_seq, y_lag1_seq, used_cell_ids

    X_seq = np.stack(X_list, axis=0).astype(np.float32)
    y_lag1_seq = np.array(y_lag1_list, dtype=np.float32).reshape(-1, 1)
    used_cell_ids = np.array(used_cell_ids)

    print("[INFO] Predict sequence 생성 결과")
    print(f"  - 사용 시퀀스 수          : {len(X_seq)}")
    print(f"  - y_lag1 미조회 제외       : {skipped_y_lag1}")
    print(f"  - feature NaN 제외         : {skipped_nan_feat}")
    print(f"  - y_lag1 타입 오류 제외    : {skipped_type}")
    print(f"  - 기타/short 제외          : {skipped_short}")
    print(f"  - X_seq shape              : {X_seq.shape}")
    print(f"  - y_lag1_seq shape         : {y_lag1_seq.shape}")
    print(f"  - y_lag1_seq min/max       : {y_lag1_seq.min():.6f} / {y_lag1_seq.max():.6f}")

    # 메모리 정리
    del feat_arr, enb_arr, win_arr, X_list, y_lag1_list
    gc.collect()

    return X_seq, y_lag1_seq, used_cell_ids




def get_seq_len_minio(config, model_type):
    """
    MinIO에 저장된 config.pbtxt 파일에서 [batch, seq_len, feature_dim] 구조의 seq_len 반환
    """

    try:
        # MinIO 설정
        endpoint_url = config['minio_server']
        access_key = config['minIO_access_key']
        secret_key = config['minIO_secret_key']
        bucket_name = config['bucket_name']

        # S3 클라이언트 생성
        s3_client = boto3.client('s3',
                                endpoint_url = endpoint_url,
                                aws_access_key_id = access_key,
                                aws_secret_access_key = secret_key,)

        obj = s3_client.get_object(Bucket=bucket_name, Key = f"{model_type}_model/cofig.pbtxt")
        text = obj["Body"].read().decode("utf-8")

        m = re.search(r'dims:\s*\[\s*-1\s*,\s*(\d+)\s*,\s*\d+\s*\]', text)
        if not m :
            raise ValueError("not found in pbtxt")

        seq_len = int(m.group(1))
        print(f"[INFO] MinIO config.pbtxt에서 읽은 sequence_length = {seq_len}")

        return seq_len

    except Exception as e:
        print("MinIO seq_len 파싱 실패 : ", e)





"""
====================================================================================
학습 모델 파이프라인
====================================================================================
"""


from torch.cuda.amp import autocast, GradScaler

def train_modeling(train_data, config, label_encoder, loop_n=0, model=None):
    """ 모델 학습을 수행하는 함수 """

    start_time = time.time()
    # Train/Validation 셋 분할
    train_df, val_df = split_train_val(train_data)
    end_time = time.time()
    diff_time = end_time - start_time
    print(f"[INFO] Train/Validation 셋 분할 생성 수행 시간 : {diff_time:.1f} S or {diff_time/60:.1f} M")

    # GPU 설정
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[INFO] Train device : {device}")

    # 모델 구조 불러오기
    if model is None:
        if config['model_type'] == 'gru':
            model = GRUModel(config).to(device)
        elif config['model_type'] == 'lstm':
            model = LSTMModel(config).to(device)
        else:
            raise ValueError("Invalid model type in config")

    # 기본 MSE (검증용)
    criterion = torch.nn.MSELoss()
    optimizer = torch.optim.Adam(
        model.parameters(),
        lr=config['learning_rate'],
        weight_decay=0.01
    )

    best_val_loss = float('inf')
    patience_counter = 0

    val_metrics_set = []

    # 임베딩 변화량 추적용
    initial_embed_weights = model.embedding.weight.data.clone().cpu()

    # -----------------------------
    # 시퀀스 생성
    # -----------------------------
    tr_X_seq, tr_y_seq, tr_y_lag1_seq, tr_module_ids, tr_bins, tr_module_bin_groups = \
        prepare_mini_batch_data(train_df, config)

    val_X_seq, val_y_seq, val_y_lag1_seq, val_module_ids, val_bins, val_module_bin_groups = \
        prepare_mini_batch_data(val_df, config)

    print(f"[INFO] train 시퀀스 수: {len(tr_X_seq)} | val 시퀀스 수: {len(val_X_seq)}")

    # 피크 관련 하이퍼파라미터
    peak_th = config.get('peak_threshold', 40.0)          # PRB 기준 (linear space)
    peak_th_log = np.log1p(peak_th).astype(np.float32)    # log1p 공간 기준
    lambda_peak = config.get('lambda_peak', 0.5)          # 피크 손실 비중

    for epoch in range(config['num_epochs']):

        if loop_n == 0:
            write_log(f"{epoch + 1}/{config['num_epochs']} 에포크 수행중")

        # -----------------------------
        # 1. Train 미니배치 제너레이터
        # -----------------------------
        train_batches_gen = create_mini_batches(
            config,
            tr_X_seq,
            tr_y_seq,
            tr_y_lag1_seq,
            tr_module_ids,
            tr_bins,
            tr_module_bin_groups,
            mode='Train',
            n_bins=10,
            epochs=epoch
        )

        val_batches_gen = create_mini_batches(
            config,
            val_X_seq,
            val_y_seq,
            val_y_lag1_seq,
            val_module_ids,
            val_bins,
            val_module_bin_groups,
            mode='Val',
            n_bins=10,
            epochs=epoch
        )

        # ---------------------------------------------------------
        # 1. Training
        # ---------------------------------------------------------
        model.train()
        epoch_loss = 0.0
        batch_count = 0
        last_bin_info = None

        scaler = GradScaler()

        for batch in tqdm(train_batches_gen, desc=f"Training Epoch {epoch + 1}", leave=False):
            # create_mini_batches 에서 (X, y, y_lag1, meta) 형태로 온다고 가정
            batch_X, batch_y, batch_y_lag1, bin_info = batch

            if bin_info is not None:
                last_bin_info = bin_info

            batch_X = torch.tensor(batch_X, dtype=torch.float32, device=device)
            batch_y = torch.tensor(batch_y, dtype=torch.float32, device=device)
            batch_y_lag1 = torch.tensor(batch_y_lag1, dtype=torch.float32, device=device)

            optimizer.zero_grad()

            with autocast():
                outputs = model(batch_X, batch_y_lag1)   # (B, 1) 또는 (B, *)

                # 출력 shape 정리: (B, 1) -> (B,)
                if outputs.dim() == 2 and outputs.size(1) == 1:
                    outputs = outputs.squeeze(1)
                elif outputs.dim() > 1:
                    # 혹시 모를 경우 첫 번째 feature만 사용 (필요시 mean(dim=1) 등으로 변경 가능)
                    outputs = outputs.view(outputs.size(0), -1)[:, 0]

                # -------------------------
                # base loss (전체 구간)
                # -------------------------
                base_loss = weighted_huber_loss(outputs, batch_y)

                # -------------------------
                # peak loss (PRB > peak_th_log)
                # -------------------------
                peak_mask = batch_y > peak_th_log
                if peak_mask.any():
                    peak_outputs = outputs[peak_mask]
                    peak_targets = batch_y[peak_mask]
                    peak_loss = weighted_huber_loss(peak_outputs, peak_targets)
                else:
                    peak_loss = torch.zeros(1, device=device)

                # 최종 loss
                loss = base_loss + lambda_peak * peak_loss

            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()

            epoch_loss += loss.item()
            batch_count += 1

        if batch_count > 0:
            avg_loss = epoch_loss / batch_count
            print(f"[Epoch {epoch+1}] Train Loss : {avg_loss:.4f}")

        # bin info 저장 (임베딩 업데이트용)
        if last_bin_info is not None:
            train_bin_to_ids = last_bin_info["train_bin_to_ids"]
            module_bin_groups = last_bin_info["module_bin_groups"]

        # ---------------------------------------------------------
        # 2. Validation
        # ---------------------------------------------------------
        val_loss = val_mse = val_mae = val_rmse = 0.0
        val_batch_count = 0

        model.eval()
        with torch.no_grad():
            for batch in val_batches_gen:
                batch_X, batch_y, batch_y_lag1, _ = batch

                batch_X = torch.tensor(batch_X, dtype=torch.float32, device=device)
                batch_y = torch.tensor(batch_y, dtype=torch.float32, device=device)
                batch_y_lag1 = torch.tensor(batch_y_lag1, dtype=torch.float32, device=device)

                with autocast():
                    outputs = model(batch_X, batch_y_lag1)

                    # 출력 shape 정리
                    if outputs.dim() == 2 and outputs.size(1) == 1:
                        outputs = outputs.squeeze(1)
                    elif outputs.dim() > 1:
                        outputs = outputs.view(outputs.size(0), -1)[:, 0]

                    loss = criterion(outputs, batch_y)

                val_loss += loss.item()

                mse = torch.mean((outputs - batch_y) ** 2)
                mae = torch.mean(torch.abs(outputs - batch_y))
                rmse = torch.sqrt(mse)

                val_mse += mse.item()
                val_mae += mae.item()
                val_rmse += rmse.item()

                val_batch_count += 1

        if val_batch_count > 0:
            val_loss /= val_batch_count
            val_mse /= val_batch_count
            val_mae /= val_batch_count
            val_rmse /= val_batch_count

        val_metrics_set.append([val_mse, val_mae, val_rmse])
        print(f"Epoch {epoch+1} | ValLoss: {val_loss:.4f}, MSE: {val_mse:.4f}, MAE: {val_mae:.4f}, RMSE: {val_rmse:.4f}")

        # Early Stopping
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            patience_counter = 0
        else:
            patience_counter += 1

        if patience_counter >= config['patience']:
            print(f"Early stopping at epoch {epoch + 1}")
            break

    # ---------------------------------------------------------
    # 3. 임베딩 업데이트
    # ---------------------------------------------------------
    label_to_index = {label: idx for idx, label in enumerate(label_encoder.classes_)}

    with torch.no_grad():
        embed_matrix = model.embedding.weight

        avg_embeds = {}
        for group, ids in train_bin_to_ids.items():
            indices = [label_to_index[uid] for uid in ids if uid in label_to_index]
            if indices:
                avg_embeds[group] = embed_matrix[indices].mean(dim=0)

        all_ids = set(label_encoder.classes_)
        untrained_ids = all_ids - set().union(*train_bin_to_ids.values())

        module_usage = train_df.groupby('enb_cell_id')['prb_usage_rate'].mean()
        bins = np.linspace(0, 100, 11)
        usage_bins = pd.cut(
            module_usage,
            bins=bins,
            labels=[f'group_{i}' for i in range(10)],
            include_lowest=True
        )

        for uid in untrained_ids:
            if uid not in usage_bins:
                continue
            group = usage_bins[uid]
            if pd.isna(group):
                continue
            group = str(group)

            if group in avg_embeds:
                idx = label_to_index.get(uid)
                if idx is not None:
                    model.embedding.weight[idx] = avg_embeds[group]

    # 메모리 정리
    del batch_X, batch_y, outputs, train_data, train_df, val_df, train_batches_gen, val_batches_gen
    gc.collect()

    metrics_set = pd.DataFrame(val_metrics_set, columns=['val_mse', 'val_mae', 'val_rmse'])
    metrics_set = metrics_set.rename(columns={
        'val_mae': 'train_mae',
        'val_mse': 'train_mse',
        'val_rmse': 'train_rmse'
    })

    final_embed_weights = model.embedding.weight.data.clone().cpu()
    delta = (initial_embed_weights - final_embed_weights).abs().mean()
    print(f"[DEBUG] 임베딩 가중치 변화량 평균: {delta:.6f}")

    return model, metrics_set





    

"""
====================================================================================
예측 과정 함수
====================================================================================
"""
import numpy as np
import torch
from torch.cuda.amp import autocast
import tritonclient.http as httpclient

def prediction(test_df, config, model_name=None):
    """
    test_df : test_preprocessing 이후 데이터프레임
    config  : 현재 config (외부에서 넘겨준 객체)
    model_name : Triton에 배포된 모델 이름 (없으면 "lstm_model" 사용)
    """

    # 1) 학습 시 저장된 config 로드
    cfg = loadMD(config, nm='md_config')
    
    # test_proc 결측이 있다면 처리
    r_cols = ["enb_cell_id", "window_end"] + cfg["feature_col"]
    before_rows = len(test_df)
    test_df = test_df.dropna(subset=r_cols).copy()
    after_rows = len(test_df)
    print(f"[INFO] NaN/NaT/NA 행 제거 : {before_rows - after_rows} rows dropped ({before_rows} -> {after_rows})")
    
    

    # 2) 시퀀스 생성    
    X_seq, y_lag1_seq, used_cell_ids = create_mini_batches_predict(test_df, cfg)
    
    # 타입 명시 (Triton / Torch 공통 안정성)
    X_seq = X_seq.astype(np.float32)
    y_lag1_seq = y_lag1_seq.astype(np.float32)
    
    print(f"[INFO] Predict X_seq shape      : {X_seq.shape}")
    print(f"[INFO] Predict y_lag1_seq shape : {y_lag1_seq.shape}")
    print(f"[INFO] Predict cell count       : {len(used_cell_ids)}")

    # 3) Triton / 로컬 분기
    if cfg.get("Triton", False):
        # ----------------- Triton 모드 -----------------
        triton_url = cfg["triton_url"]
        used_model_name = model_name or "lstm_model"

        client = httpclient.InferenceServerClient(
            url=triton_url,
            verbose=False
        )

        # INPUT__0: X_seq
        inp0 = httpclient.InferInput(
            "INPUT__0", X_seq.shape, "FP32"
        )
        inp0.set_data_from_numpy(X_seq)

        # INPUT__1: y_lag1_seq
        inp1 = httpclient.InferInput(
            "INPUT__1", y_lag1_seq.shape, "FP32"
        )
        inp1.set_data_from_numpy(y_lag1_seq)

        outputs = [
            httpclient.InferRequestedOutput("OUTPUT__0")
        ]

        response = client.infer(
            model_name=used_model_name,
            inputs=[inp0, inp1],
            outputs=outputs
        )

        preds = response.as_numpy("OUTPUT__0")

    else:
        # --------------- 로컬 PyTorch 모드 ---------------
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

        model = loadMD(cfg, nm="model")
        model.to(device)
        model.eval()

        X_t = torch.from_numpy(X_seq).to(device)
        y_lag1_t = torch.from_numpy(y_lag1_seq).to(device)

        with torch.no_grad():
            with autocast(enabled=torch.cuda.is_available()):
                preds = model(X_t, y_lag1_t).cpu().numpy()
                
    # 4) 출력 shape 통일 (N,)    
    preds = np.asarray(preds).reshape(-1)

    return preds, used_cell_ids


from datetime import timedelta
import numpy as np
import pandas as pd
import torch

def post_processing(pred, used_cell_ids, test_df, label, config):
    """
    pred          : 모델 출력 (log1p 스케일 상태, shape: (N,) 또는 (N,1))
    used_cell_ids : create_mini_batches_predict에서 실제로 사용된 enb_cell_id 배열
    test_df       : 전처리된 추론용 데이터
    label         : cell_info (enb_cell_id, cell_type, freq_type)
    config        : md_config
    """

    # 1) 스케일 복원
    if config['scaler'] == 'log1p':
        if isinstance(pred, torch.Tensor):
            pred = pred.cpu().numpy()
        preds_scaled = np.expm1(pred.astype(np.float64)).reshape(-1)
    else:
        scaler_y = loadMD(config, nm='scaler_y_')
        preds_scaled = scaler_y.inverse_transform(
            np.array(pred).reshape(-1, 1)
        ).reshape(-1)

    valid_cell_ids = np.array(used_cell_ids)
    print(f"[INFO] post_processing: valid_cell_ids 수 = {len(valid_cell_ids)}, preds 수 = {len(preds_scaled)}")

    # 길이 sanity check (여기서는 진짜 문제가 있으면만 경고)
    if len(valid_cell_ids) != len(preds_scaled):
        min_len = min(len(valid_cell_ids), len(preds_scaled))
        print(f"[WARN] cell_id({len(valid_cell_ids)}) != preds({len(preds_scaled)}), "
              f"앞에서부터 {min_len}개만 사용합니다.")
        valid_cell_ids = valid_cell_ids[:min_len]
        preds_scaled = preds_scaled[:min_len]

    # 2) label 매핑
    label_indexed = label.set_index('enb_cell_id')
    label_sub = label_indexed.loc[valid_cell_ids].reset_index()

    cell_type = label_sub['cell_type'].values
    freq_type = label_sub['freq_type'].values

    # 3) window_start / window_end 계산 (모든 row 동일)
    win_start = pd.to_datetime(test_df['window_start']).max() + timedelta(minutes=5)
    win_end   = pd.to_datetime(test_df['window_end']).max() + timedelta(minutes=5)

    # 4) 결과 DataFrame 생성
    result = pd.DataFrame({
        'cell_id': valid_cell_ids,
        'cell_type': cell_type,
        'freq_type': freq_type,
        'window_start': win_start,
        'window_end': win_end,
        'model_type': config['model_type'],
        'prb_usage_predicted': preds_scaled
    })

    # 5) 0~100 클리핑 + 반올림
    result['prb_usage_predicted'] = np.clip(
        result['prb_usage_predicted'], 0, 100
    ).round(2)

    return result




"""
====================================================================================
정확도 성능지표 관련 함수
====================================================================================
"""
# MSE, MAE, RMSE, MAPE를 한 번에 계산하는 함수
def compute_metrics(y_true, y_pred):
    # MSE (Mean Squared Error)
    mse = torch.mean((y_true - y_pred) ** 2)

    # MAE (Mean Absolute Error)
    mae = torch.mean(torch.abs(y_true - y_pred))

    # RMSE (Root Mean Squared Error)
    rmse = torch.sqrt(mse)

    # MAPE (Mean Absolute Percentage Error)
    epsilon = 1e-10  # 작은 값으로 나누기 0을 방지
    mape = torch.mean(torch.abs((y_true - y_pred) / (y_true + epsilon))) * 100

    return mse, mae, rmse, mape



def df_processing_acc(*args, **kwargs):
    df = args[0]
    config = args[1]


    if 'true' in kwargs.get('type'):
        
        df['window_end'] = pd.to_datetime(df['window_end'])
        df['prb_usage_rate'] = df['prb_usage_rate'].astype(int)
        df = df.rename(columns = {'enb_cell_id':'cell_id'})


    else:
        df['window_end'] = pd.to_datetime(df['window_end'])
        df = df.rename(columns={'prb_usage_predicted':'yhat'})

    return df


def accuracy_value(df):

    result = pd.DataFrame({
            'infer_mae' : [round(mean_absolute_error(df['prb_usage_rate'], df['yhat']), 3)],
            'infer_mse' : [round(mean_squared_error(df['prb_usage_rate'], df['yhat']),3)],
            'infer_rmse' : [round(np.sqrt(mean_squared_error(df['prb_usage_rate'], df['yhat'])),3)],
            'infer_mape' : [round(np.mean(np.abs((df['prb_usage_rate']-df['yhat'])/(df['prb_usage_rate']+1e-9)))*100, 3)]})

    return result.reset_index(drop=True)



def accuracy_(*args, **kwargs):
    try:
        start_time = time.time()

        ture_df = args[0]
        pred_df = args[1]
        minutes_bef = args[2]
        now = args[3]
        config = args[4]


        if ture_df.empty or pred_df.empty:
            print(f"==== DataFrame Empty ====")

        else:

            tot_result = pd.DataFrame()
            for i in range(len(pred_df['model_type'].unique())):

                alg = pred_df['model_type'].unique()[i]
                pred_df_sub = pred_df[pred_df['model_type'] == alg]

                chunk_size = 10000
                pred_df_chunks = np.array_split(pred_df_sub, len(pred_df_sub)//chunk_size+1)

                for chunk in pred_df_chunks:


                    #개발 TB - 최종
                    df = pd.merge(chunk, ture_df, on = ['cell_id', 'window_end', 'cell_type','freq_type'], how='inner')
                    df = df.dropna().reset_index(drop=True)
                    print(f"==================== 데이터 합치기 완료 ====================")

                    result = df.groupby(['cell_id', 'cell_type', 'freq_type']).apply(accuracy_value).reset_index()

                    if 'level_3' in result.columns:
                        result = result.drop(columns='level_3')

                    # 정확도 - 후처리
                    result['infer_mape'] = np.where(result['infer_mape'] <= 0, 0, np.where(result['infer_mape'] >= 100, 100, result['infer_mape']))
                    result['model_type'] = alg

                    result['window_start'] = pd.to_datetime(minutes_bef.strftime('%Y-%m-%d %H:%M:00'))- timedelta(hours=1)
                    result['window_end'] = pd.to_datetime(now.strftime('%Y-%m-%d %H:%M:59')) - timedelta(hours=1)
                    result = result[['model_type', 'cell_id', 'cell_type', 'window_start', 'window_end', 'freq_type', 'infer_mae', 'infer_mse', 'infer_rmse', 'infer_mape']]
                    
                    
                    result = result.rename(columns={'infer_mae':'train_mae', 'infer_mse':'train_mse', 'infer_rmse':'train_rmse', 'infer_mape':'train_mape'})
                    
                    decimal_col = ['infer_mae', 'infer_mse', 'infer_rmse', 'infer_mape']
                    for c in decimal_col:
                        hist[c] = (pd.to_numeric(hist[c], errors="coerce").round(3).astype("float64"))

                    # 정확도 저장
                    saveMD(config, result, nm = 'accuracy_')


            end_time = time.time()
            diff_time = end_time-start_time
            print(f"정확도 계산 시간 : {diff_time/60} M")
            print("==================== 모델 성능 평가 완료 ====================")


    except Exception as e:
        print(f'Error occurred in accuracy_: {e}')


"""
====================================================================================
minIO, Triton 관련 함수
====================================================================================
"""
def triton_server(config):

    TRITON_SERVER_URL = config['triton_url']

    # Triton 클라이언트 초기화
    try:
        client = httpclient.InferenceServerClient(url=TRITON_SERVER_URL)
    except Exception as e:
        print(f"Failed to create Triton client: {e}")
        raise

    return client

    
def triton_model_config():
    original_text = """
name: "lstm_model"
platform: "pytorch_libtorch"
max_batch_size: 0
input [
  {
    name: "INPUT__0"
    data_type: TYPE_FP32
    dims: [-1, 100, 18]
  },
  {
    name: "INPUT__1"
    data_type: TYPE_FP32
    dims: [-1, 1]
  }
]
output [
  {
    name: "OUTPUT__0"
    data_type: TYPE_FP32
    dims: [-1, 1]
  }
]
"""
    return original_text



import re

def modify_model_configuration(text, new_name, new_dims_input_1=None, new_dims_output=None):
    """
    Triton config 텍스트에서
      - 모델 이름(name)
      - 첫 번째 input dims
      - (선택) output dims
    을 교체하는 함수
    """
    # 1) name 교체
    model_name_pattern = r'name:\s*"([^"]+)"'
    new_name_str = f'name: "{new_name}"'
    modified_text = re.sub(model_name_pattern, new_name_str, text, count=1)

    # 2) 첫 번째 dims (INPUT__0) 교체
    if new_dims_input_1 is not None:
        # 첫 번째 dims: [...] 만 치환
        dims_pattern_1 = r'dims:\s*\[(.*?)\]'
        new_dims_str_1 = "dims: " + str(new_dims_input_1)
        modified_text = re.sub(dims_pattern_1, new_dims_str_1, modified_text, count=1)

    # 3) (옵션) OUTPUT dims 교체
    if new_dims_output is not None:
        # output [ ... dims: [ -1, 1 ] ... ] 부분만 치환
        dims_pattern_2 = r'dims:\s*\[\s*-1\s*,\s*1\s*\]'
        new_dims_str_2 = "dims: " + str(new_dims_output)
        modified_text = re.sub(dims_pattern_2, new_dims_str_2, modified_text, count=1)

    return modified_text



def create_inference_config(save_path, config, name=None):
    original_text = triton_model_config()

    # 1) 모델 이름 교체
    new_name = name or "lstm_model"
    model_name_pattern = r'name:\s*"([^"]+)"'
    new_name_str = f'name: "{new_name}"'
    modified = re.sub(model_name_pattern, new_name_str, original_text, count=1)

    # 2) INPUT__0 dims 교체: [-1, seq_len, feature_dim]
    input0_pattern = r'(input\s*\[\s*\{\s*name:\s*"INPUT__0".*?dims:\s*)\[(.*?)\](.*?\})'
    input0_repl = (
        r'\1['
        f'-1, {config["sequence_length"]}, {len(config["feature_col"])}'
        r']\3'
    )
    modified = re.sub(input0_pattern, input0_repl, modified, flags=re.S)

    # INPUT__1, OUTPUT__0 는 [-1,1] 고정이면 굳이 건드릴 필요 없음

    with open(save_path, "w") as f:
        f.write(modified)

    print("[INFO] 생성된 Triton config.pbtxt:")
    print(modified)




def copy_and_rename_folder_v0(src_folder, dest_folder_name):

    # 원본 폴더가 존재하는지 확인
    if not os.path.exists(src_folder):
        print(f"원본 폴더 '{src_folder}'이(가) 존재하지 않습니다.")
        return

    # 목적지 폴더 경로 생성
    parent_dir = os.path.dirname(os.path.dirname(src_folder))  # 원본 폴더의 부모 디렉토리
    dest_folder = os.path.join(parent_dir, dest_folder_name)

    # 이미 존재하는 폴더가 있으면 삭제
    if os.path.exists(dest_folder):
        print(f"'{dest_folder}' 폴더가 이미 존재합니다. 덮어쓰기를 진행합니다.")
        shutil.rmtree(dest_folder)  # 기존 폴더를 삭제

    # 폴더 복사
    shutil.copytree(src_folder, dest_folder)
    print(f"폴더 '{src_folder}'이(가) '{dest_folder}'로 복사되었습니다.")



def copy_and_rename_folder(src_folder, dest_folder_name):

    # 원본 폴더가 존재하는지 확인
    if not os.path.exists(src_folder):
        print(f"원본 폴더 '{src_folder}'이(가) 존재하지 않습니다.")
        return

    # 목적지 폴더 경로 생성
    parent_dir = os.path.dirname(os.path.dirname(src_folder))  # 원본 폴더의 부모 디렉토리
    dest_folder = os.path.join(parent_dir, dest_folder_name)

    # src 내부에 있는 파일들을 dest로 복사(덮어쓰기)
    for item in os.listdir(src_folder):
        s = os.path.join(src_folder, item)
        d = os.path.join(dest_folder, item)

        # 폴더인 경우
        if os.path.isdir(s):
            # 기존에 있으면 삭제 후 다시 복사
            if os.path.exists(d):
                shutil.rmtree(s,d)
            shutil.copytree(s,d)
        else:
            shutil.copy2(s,d)
    print(f"폴더 '{src_folder}'이(가) '{dest_folder}'로 복사되었습니다.")


    # 날짜 폴더 삭제
    if os.path.exists(src_folder):
        print(f"'{src_folder}' 폴더가 존재합니다. 해당 폴더를 삭제합니다.")
        shutil.rmtree(src_folder)
        print(f"'{src_folder}' 폴더를 삭제했습니다.")
        

    

def upload_folder_to_minio(config, local_path, **kwargs):

    """
    로컬 디렉토리를 MinIO로 업로드합니다.

    :param endpoint_url: MinIO 서버의 엔드포인트 URL
    :param access_key: MinIO 액세스 키
    :param secret_key: MinIO 시크릿 키
    :param bucket_name: 업로드할 버킷 이름
    :param local_path: 업로드할 로컬 디렉토리 경로
    :param minio_folder_path: MinIO 내 업로드 대상 폴더 경로
    """
    try:

        endpoint_url = config['minio_server']
        access_key = config['minIO_access_key']
        secret_key = config['minIO_secret_key']
        bucket_name = config[kwargs.get('target')]


        # S3 클라이언트 생성
        s3_client = boto3.client(
            's3',
            endpoint_url=endpoint_url,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )

        minio_folder_path = "/"  # MinIO 내 업로드 대상 폴더 경로

        # 로컬 디렉토리 이름을 포함해 업로드 경로 생성
        folder_name = os.path.basename(os.path.normpath(local_path))
        minio_folder_path = os.path.join(minio_folder_path, folder_name).replace("\\", "/")

        if bucket_name == 'model-repo-history':
            local_path = os.path.dirname(local_path)

        # 로컬 디렉토리 내 모든 파일 및 폴더 탐색
        for root, _, files in os.walk(local_path):
            for file in files:
                local_file_path = os.path.join(root, file)

                # MinIO 내 저장 경로 생성
                relative_path = os.path.relpath(local_file_path, local_path)
                s3_key = os.path.join(minio_folder_path, relative_path).replace("\\", "/")  # 윈도우 호환성

                # MinIO로 파일 업로드
                print(f"Uploading: {local_file_path} to {bucket_name}/{s3_key}")
                s3_client.upload_file(local_file_path, bucket_name, s3_key)

        print(f"로컬 폴더 '{local_path}'가 MinIO의 '{minio_folder_path}'로 성공적으로 업로드되었습니다.")
        return {"success": True, "error": None}

    except Exception as e:
        # 에러 발생 시 상세 정보를 기록
        error_message = f"폴더 업로드 실패: {str(e)}"
        traceback.print_exc()  # 에러 로그 출력 (선택 사항)
        return {"success": False, "error": error_message}



def delete_check_folders_from_minio(config, **kwargs):
    """
    MinIO에서 이름에 'check'가 포함된 폴더를 삭제합니다.

    :param config: MinIO 설정을 포함한 딕셔너리
    :param kwargs: 추가 인자, 예를 들어 target 버킷 이름
    """

    endpoint_url = config['minio_server']
    access_key = config['minIO_access_key']
    secret_key = config['minIO_secret_key']
    bucket_name = config[kwargs.get('storage')]
    folder_prefix = kwargs.get('target')+'/'  # 폴더 경로는 Prefix로 처리

    try:
        # S3 클라이언트 생성
        s3_client = boto3.client(
            's3',
            endpoint_url=endpoint_url,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )

        # 1) 기존 check 포함 폴더 삭제
        check_prefix = folder_prefix + 'check'
        response = s3_client.list_objects_v2(Bucket=bucket_name, Prefix=check_prefix)

        if 'Contents' in response:
            # "check"가 포함된 객체 목록 생성
            objects_to_delete = [{'Key': obj['Key']} for obj in response['Contents']]

            if obhect_to_delete :
                print(f"삭제할 객체 목록: {objects_to_delete}")
                
                # 객체 삭제 요청
                delete_response = s3_client.delete_objects(
                    Bucket=bucket_name,
                    Delete={
                        'Objects': objects_to_delete,
                        'Quiet': True
                    }
                )
                print(f"MinIO에서 이름에 'check'가 포함된 폴더가 삭제되었습니다.")
            else:
                print(f"MinIO에서 이름에 'check'가 포함된 객체가 없습니다. 아무 작업도 수행하지 않습니다.")

        # 2) 추가 model_yyyymmdd 형식 폴더 삭제
        model_type = config.get('model_type', '').strip()
        if model_type:
            #lstm_model/lstm_으로 시작하는 모든 객체
            version_prefix = folder_prefix + f"{model_type}_"
            resp_ver = s3_client.list_objects_v2(Bucket=bucket_name, Prefix=version_prefix)

            if 'Contents' in resp_ver:
                ver_object_to_delete = [{'Key': obj['Key']} for obj in resp_ver['Contents']]
                if ver_object_to_delete:
                    print(f"MinIO 삭제 대상 ({model_type}_YYYYMMDD) : {ver_object_to_delete}")
                    s3_client.delete_objects(Bucket=bucket_name, Delete = {'Objects': ver_object_to_delete, 'Quiet': True})
                    print(f"MinIO에서 '{model_type}_YYYYMMDD' 버전 폴더가 삭제되었습니다.")

            else:
                #해당 버전 폴더가 없는 경우 패스
                print(f"MinIO에 '{model_type}_YYYYMMDD' 버전 폴더는 없습니다.")
            

    except Exception as e:
        print("폴더 삭제 실패:", e)



def download_folder_from_minio(config, **kwargs):

    """
    MinIO에서 특정 폴더를 로컬로 다운로드합니다 (폴더 경로 포함).

    :param endpoint_url: MinIO 서버의 엔드포인트 URL
    :param access_key: MinIO 액세스 키
    :param secret_key: MinIO 시크릿 키
    :param bucket_name: 다운로드할 버킷 이름
    :param folder_path: 다운로드할 폴더 경로 (MinIO 내 경로)
    :param local_path: 로컬에 저장할 경로
    """



    try:

        # MinIO 설정
        endpoint_url = config['minio_server']
        access_key = config['minIO_access_key']
        secret_key = config['minIO_secret_key']
        bucket_name = config[kwargs.get('storage')]
        folder_path = kwargs.get('target') # MinIO 내 폴더 경로 (슬래시 포함)
        local_path = "./"  # 로컬에 저장할 경로

        # S3 클라이언트 생성
        s3_client = boto3.client(
            's3',
            endpoint_url=endpoint_url,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )

        # MinIO 버킷에서 지정된 폴더의 객체 리스트 가져오기
        response = s3_client.list_objects_v2(Bucket=bucket_name, Prefix=folder_path)

        if 'Contents' not in response:
            print(f"폴더 '{folder_path}' 내에 다운로드할 파일이 없습니다.")
            return

        # 객체 리스트 반복 처리
        for obj in response['Contents']:
            key = obj['Key']
            # 로컬 경로 생성: folder_path를 포함하여 저장
            local_file_path = os.path.join(local_path, key)

            # 로컬 디렉토리가 존재하지 않으면 생성
            os.makedirs(os.path.dirname(local_file_path), exist_ok=True)

            # MinIO에서 객체 다운로드
            print(f"Downloading: {key} to {local_file_path}")
            s3_client.download_file(bucket_name, key, local_file_path)

        print(f"폴더 '{folder_path}'가 로컬 경로 '{local_path}'에 성공적으로 다운로드되었습니다.")

    except Exception as e:
        print("모델 폴더 다운로드 실패:", e)

#   cell_usage_1m, cell_usage_1m_latest 테이블에 데이터를 삽입
def create_data_daily(config):

    # ClickHouse 클라이언트 생성
    client = clickhouse_connect.get_client(
        host=config['db_host'],
        port=config['db_port'],
        username=config['db_username'],
        password=config['db_password'],
        database=config['db_database'],
        connect_timeout=3000000,  # 연결 타임아웃 (초)
        send_receive_timeout=3000000  # 요청/응답 타임아웃 (초)
    )

    # cell_usage_1m_latest 데이터 삽입
    insert_query = f'''
    insert into ai.cell_usage_1m_latest
    WITH
    tumble(now(), toIntervalMinute(1)) AS current_window,
    current_window.1 AS current_window_start, -- 최근 1분 데이터 가져오는 방법 : current_window_start = window_end
    all_ids AS (
        SELECT cell_id, cell_type, freq_band_val AS freq_type FROM nwdaf.all_cell_data
    ), -- 전체 ID 리스트 통합
    mdn_cell_usage AS (
        SELECT
            mdn, cell_id, window_start, window_end,
            sumMerge(sum_dl_usage) AS dl_usage, 
            sumMerge(sum_duration) AS duration,
            CAST((8 * dl_usage) / duration, 'UInt64') AS dl_bps,
            anyMerge(heavy_threshold) AS heavy_threshold,
            anyMerge(medium2_threshold) AS medium2_threshold,
            anyMerge(medium1_threshold) AS medium1_threshold,
            dl_bps >= heavy_threshold AS is_heavy,
            (NOT is_heavy) AND (dl_bps >= medium2_threshold) AS is_medium2,
            (NOT (is_heavy OR is_medium2)) AND (dl_bps >= medium1_threshold) AS is_medium1,
            NOT (is_heavy OR is_medium2 OR is_medium1) AS is_light
        FROM nwdaf.t_window_mdn_cell
        WHERE
            window_end >= current_window_start - INTERVAL 5 MINUTE
        GROUP BY mdn, cell_id, window_start, window_end
        HAVING duration > 0
    ),
    cell_usage AS (
        SELECT
            cell_id, window_start, window_end,
            sum(duration) AS total_duration,
            sum(dl_usage) AS total_dl, uniq(mdn) AS total_user,
            sumIf(dl_usage, is_heavy) AS heavy_dl, uniqIf(mdn, is_heavy) AS heavy_user,
            sumIf(dl_usage, is_medium2) AS medium2_dl, uniqIf(mdn, is_medium2) AS medium2_user,
            sumIf(dl_usage, is_medium1) AS medium1_dl, uniqIf(mdn, is_medium1) AS medium1_user,
            sumIf(dl_usage, is_light) AS light_dl, uniqIf(mdn, is_light) AS light_user
        FROM mdn_cell_usage
        GROUP BY cell_id, window_start, window_end
    ),
    cell_usage_5m_sum AS (
    SELECT
        cell_id,
        window_end,
        SUM(total_user) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS total_user_count_5m,
        SUM(heavy_user) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS heavy_user_count_5m,
        SUM(medium2_user) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS medium2_user_count_5m,
        SUM(medium1_user) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS medium1_user_count_5m,
        SUM(light_user) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS light_user_count_5m,
        SUM(total_dl) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS total_user_usage_5m,
        SUM(heavy_dl) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS heavy_user_usage_5m,
        SUM(medium2_dl) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS medium2_user_usage_5m,
        SUM(medium1_dl) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS medium1_user_usage_5m,
        SUM(light_dl) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS light_user_usage_5m,
        SUM(total_duration) OVER (PARTITION BY cell_id ORDER BY window_end ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) / 5 AS duration_5m
    FROM cell_usage
    ORDER BY cell_id, window_start
    ) -- 최근 5분의 과금 데이터 평균
    SELECT
        x.cell_id AS enb_cell_id,
        x.cell_type AS cell_type,
        x.freq_type AS freq_type,
        current_window_start - INTERVAL 5 MINUTE AS window_start,
        current_window_start AS window_end,
        COALESCE(toDayOfWeek(current_window_start), 0) AS day_of_week,
        CASE WHEN toDayOfWeek(current_window_start) >= 6 THEN 1 ELSE 0 END AS is_weekend,
        COALESCE(toHour(current_window_start), 0) AS hh,
        a.total_user AS total_user_count,
        a.heavy_user AS heavy_user_count,
        a.medium2_user AS medium2_user_count,
        a.medium1_user AS medium1_user_count,
        a.light_user AS light_user_count,
        b.total_user_count_5m AS total_user_count_5m,
        b.heavy_user_count_5m AS heavy_user_count_5m,
        b.medium2_user_count_5m AS medium2_user_count_5m,
        b.medium1_user_count_5m AS medium1_user_count_5m,
        b.light_user_count_5m AS light_user_count_5m,
        c.total_user_count_avg AS total_user_count_avg,
        ROUND(COALESCE(NULLIF(toFloat32(a.total_user), 0) / NULLIF(toFloat32(c.total_user_count_avg), 0), 0), 3) AS total_user_count_rate,
        ROUND(COALESCE(NULLIF(toFloat32(b.total_user_count_5m), 0) / NULLIF(toFloat32(c.total_user_count_avg), 0), 0) / 5, 3) AS total_user_count_rate_5m,
        a.total_dl AS total_user_usage,
        a.heavy_dl AS heavy_user_usage,
        a.medium2_dl AS medium2_user_usage,
        a.medium1_dl AS medium1_user_usage,
        a.light_dl AS light_user_usage,
        b.total_user_usage_5m AS total_user_usage_5m,
        b.heavy_user_usage_5m AS heavy_user_usage_5m,
        b.medium2_user_usage_5m AS medium2_user_usage_5m,
        b.medium1_user_usage_5m AS medium1_user_usage_5m,
        b.light_user_usage_5m AS light_user_usage_5m,
        c.total_user_usage_avg AS total_user_usage_avg,
        ROUND(COALESCE(NULLIF(toFloat32(a.total_dl), 0) / NULLIF(toFloat32(c.total_user_usage_avg), 0), 0), 3) AS total_user_usage_rate,
        ROUND(COALESCE(NULLIF(toFloat32(b.total_user_usage_5m), 0) / NULLIF(toFloat32(c.total_user_usage_avg), 0), 0) / 5, 3) AS total_user_usage_rate_5m,
        a.total_duration AS duration,
        b.duration_5m AS duration_5m,
        NULL AS prb_usage_rate -- prb사용율은 5분 주기 데이터가 1시간마다 수집이 되므로 현 시점의 prb사용율을 얻을 수 없음. 0으로 입력
    FROM all_ids x
        LEFT JOIN (select * from cell_usage WHERE window_end = current_window_start) a
        ON x.cell_id = a.cell_id
    LEFT JOIN cell_usage_5m_sum b
        ON x.cell_id = b.cell_id
        AND a.window_end = b.window_end
    LEFT JOIN ai.cell_usage_1wk_avg c
        ON a.cell_id = c.cell_id
        AND toDate(a.window_end) = toDate(c.create_dt)
    '''
    
    client.query(insert_query)
    
    # cell_usage_1m 데이터 삽입
    insert_query = f'''insert into ai.cell_usage_1m select * from ai.cell_usage_1m_latest
    where toDateTime(window_end) = '{datetime.now().strftime("%Y-%m-%d %H:%M:00")}'
    '''

    client.query(insert_query)