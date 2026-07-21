import os
import logging
import numpy as np
from pathlib import Path
from PIL import Image
from skimage import measure
import cv2

logger = logging.getLogger(__name__)

class AIModelService:
    def __init__(self, model_path: str = "model.onnx"):
        """
        初始化 AI 推理服务。
        - 如果 model.onnx 存在，使用 ONNX 推理
        - 否则降级到内置数学模拟（基于信息熵和纹理跳变）
        """
        self.model_path = model_path
        self.onnx_session = None
        self.use_onnx = False
        
        if os.path.exists(model_path):
            try:
                import onnxruntime as rt
                self.onnx_session = rt.InferenceSession(
                    model_path,
                    providers=['CPUExecutionProvider']
                )
                self.use_onnx = True
                logger.info(f"✓ ONNX 模型已加载: {model_path}")
            except Exception as e:
                logger.warning(f"⚠ ONNX 加载失败，降级到数学模拟: {e}")
                self.use_onnx = False
        else:
            logger.info(f"⚠ 未找到 {model_path}，使用内置数学模拟")
            self.use_onnx = False
    
    def predict_ai_score(self, image_path: str) -> float:
        """
        预测图像的 AI 建模痕迹分数 (0.0 ~ 1.0)。
        - ONNX 模式：通过深度学习推理
        - 降级模式：通过信息熵 + 纹理特征数学计算
        """
        try:
            img = Image.open(image_path).convert('RGB')
            img_resized = img.resize((224, 224), Image.LANCZOS)
            img_array = np.array(img_resized, dtype=np.float32) / 255.0
            
            if self.use_onnx and self.onnx_session:
                return self._infer_onnx(img_array)
            else:
                return self._fallback_math_model(np.array(img_resized, dtype=np.uint8))
        except Exception as e:
            logger.error(f"AI 推理失败: {e}")
            return 0.5  # 中立分数
    
    def _infer_onnx(self, img_array: np.ndarray) -> float:
        """
        ONNX 模型前向推理。
        期望输入: (1, 3, 224, 224) 的 NCHW 格式归一化 float32 数组
        """
        try:
            input_name = self.onnx_session.get_inputs()[0].name
            input_data = np.expand_dims(img_array, axis=0)
            if input_data.shape != (1, 3, 224, 224):
                # 调整到 NCHW
                input_data = np.transpose(input_data, (0, 3, 1, 2))
            
            output = self.onnx_session.run(None, {input_name: input_data})
            # 假设输出是 [batch, 1] 或 [batch, 2]（二分类 logits 或概率）
            score = float(output[0][0][0]) if output else 0.5
            return np.clip(score, 0.0, 1.0)
        except Exception as e:
            logger.error(f"ONNX 推理异常: {e}")
            return 0.5
    
    def _fallback_math_model(self, img_uint8: np.ndarray) -> float:
        """
        降级方案：基于信息熵 + 局部纹理周期性的数学模型。
        模拟 AI 生成图像的"非自然纹理"特征。
        """
        try:
            # 转灰度
            if len(img_uint8.shape) == 3:
                gray = cv2.cvtColor(img_uint8, cv2.COLOR_RGB2GRAY)
            else:
                gray = img_uint8
            
            # 1. 信息熵特征：AI 生成的图像往往熵较低（纹理规则）
            hist = np.histogram(gray, bins=256, range=(0, 256))[0]
            hist = hist[hist > 0] / hist.sum()
            entropy = -np.sum(hist * np.log2(hist + 1e-10))
            entropy_score = 1.0 - (entropy / 8.0)  # 归一化到 [0, 1]
            
            # 2. 纹理周期性特征：AI 笔触有高频重复
            # 计算 Laplacian 能量（边缘/纹理强度）
            laplacian = cv2.Laplacian(gray, cv2.CV_64F)
            texture_energy = np.mean(np.abs(laplacian))
            texture_score = np.tanh(texture_energy / 50.0)  # 归一化
            
            # 3. 局部对比度不一致性
            # 分块计算对比度，计算其方差（不一致度高 -> 修改痕迹）
            h, w = gray.shape
            block_h, block_w = h // 4, w // 4
            contrasts = []
            for i in range(4):
                for j in range(4):
                    block = gray[i*block_h:(i+1)*block_h, j*block_w:(j+1)*block_w]
                    contrasts.append(np.std(block))
            contrast_variance = np.var(contrasts) if contrasts else 0
            consistency_score = 1.0 - np.tanh(contrast_variance / 500.0)
            
            # 4. 融合多个特征
            # AI 痕迹通常表现为：低熵 + 中等纹理能量 + 不一致对比
            ai_score = (
                0.4 * entropy_score +      # AI 生成往往熵低
                0.3 * texture_score +      # 纹理规则性
                0.3 * (1.0 - consistency_score)  # 对比度不均匀
            )
            
            return float(np.clip(ai_score, 0.0, 1.0))
        except Exception as e:
            logger.error(f"数学模型计算失败: {e}")
            return 0.5
