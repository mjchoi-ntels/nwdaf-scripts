import os
import warnings
import pandas as pd
import numpy as np
import ast
from sklearn.preprocessing import StandardScaler, MinMaxScaler, LabelEncoder
import torch
from torch.utils.data import DataLoader, TensorDataset
from IPython.display import display 
from utils import *
from model_config import config
import sys


def main():
    
    
    warnings.filterwarnings('ignore')

    # write_log(f"Start cell_usage_1m creattion...")
    # create_data_daily(config)
    # print("create_data_daily 완료")
    
    config['type'] = 'predict'
    config['model_type'] = 'lstm'
    new_dir_name = 'lstm_model'
    old_load_dir_path = config['model_save_path']
    config['model_save_path'] = os.path.join(os.path.dirname(old_load_dir_path.rstrip('/')), new_dir_name)



    # 모델 폴더 다운로드 실행
    download_folder_from_minio(config, storage = 'bucket_name', target = new_dir_name)
    

    # 1) 추론할 현재 시간
    infer_time = config['now_dt']
    
    # 2) 학습 이력 관리 테이블
    cell_ = train_hist_load(config)

    
    # 추론
    if not cell_.empty:
        total_start = time.time()

        # 2) 데이터 로드
        start = time.time()
        
        shard_id = os.environ.get("SHARD_ID")
        if shard_id is None:
            raise EnvironmentError("SHARD_ID 환경 변수가 없습니다.")
        num_shards = os.environ.get("NUM_SHARDS")
        if num_shards is None:
            raise EnvironmentError("NUM_SHARDS 환경 변수가 없습니다.")
            
        print(f"[INFO] shard {shard_id}/{num_shards}")
        
        data = test_data_load(config, infer_time, shard_id=shard_id, num_shards=num_shards)
        print(f"[INFO] Test Cell count : {data['enb_cell_id'].nunique()} / 추론 데이터 길이  : {len(data)}")
        
              
        end = time.time()
        print(f"[INFO] 데이터 로드 처리 시간 : {end - start:.2f}초")
 
            
        # 기지국 별 청크 분할 추론 
        data = data.sort_values(['enb_cell_id', 'window_start'])
        all_cells = data['enb_cell_id'].unique()
        cell_chunk_size = int(50000)
        
        data = data.set_index('enb_cell_id', drop=False)

        
        all_result_list = []
        
        for start in range(0, len(all_cells), cell_chunk_size):

            end = start + cell_chunk_size
            if end > len(all_cells):
                end = len(all_cells)

            batch_cells = all_cells[start:end]
            
            # data_chunk = data[data['enb_cell_id'].isin(batch_cells)]
            data_chunk = data.loc[batch_cells]
            data_chunk = data_chunk.reset_index(drop=True)
            
            end = int(end)

            print(f"\n [INFO] 청크 처리 : rows {start} ~ {end - 1} "
                 f"(기지국 수 : {len(batch_cells)}, 행 수 : {len(data_chunk)})")
            

            # 3) 데이터 전처리
            start = time.time()
            test_proc, cell_info = test_preprocessing(data_chunk, config)
            end = time.time()
            print(f"데이터 전처리 처리 시간 : {end - start:.2f}초")
            
            
            # 4) 예측
            start = time.time()
            pred, used_cell_ids = prediction(test_proc, config, model_name=new_dir_name)

            end = time.time()
            print(f"추론 처리 시간 : {end - start:.2f}초")


            # 5) 후처리(DB 저장용)
            start = time.time()
            result = post_processing(pred, used_cell_ids, test_proc, cell_info, config)
            end = time.time()
            print(f"후처리 시간 : {end - start:.2f}초")

            all_result_list.append(result)

            # 메모리 정리
            del data_chunk, test_proc, pred, result
            torch.cuda.empty_cache()
            
            # break

            
        final_df = pd.concat(all_result_list, axis=0, ignore_index=True)

        final_df = final_df.fillna({
            **{col: 0 for col in final_df.select_dtypes(include=['number']).columns},
            **{col: '' for col in final_df.select_dtypes(include=['object', 'string']).columns}
        })

        if final_df.isna().any().any():
            raise ValueError("[ERROR] final_df에 NaN/pd.Na값이 포함되어 있습니다.")

        print("===== 예측 결과 (변수 처리 후) =====")
        print(final_df.head())
        print(final_df.columns)
        print(final_df.isnull().sum())
        print(max(final_df['window_end']))
        print(min(final_df['window_end']))

        # 6) 예측 결과 저장
        cols = ['cell_id', 'cell_type', 'window_start', 'window_end', 'freq_type', 'model_type', 'prb_usage_predicted']
        final_df = final_df[cols]

        saveMD(config, final_df, nm = 'predict_')

        total_end = time.time()
        print(f"총 소요시간 {total_end - total_start:.2f}초")



    else:
        print(f"{config['model_type']} 알고리즘으로 학습된 모델이 없습니다.")


        
if __name__ == "__main__":
    main()