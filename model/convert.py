import numpy as np, torch, coremltools as ct
from onnx2torch import convert as onnx2torch_convert

# InsightFace's ArcFace ONNX takes RGB, 112x112, scaled to [-1, 1]:
#   blobFromImages(1/127.5, (112,112), mean=127.5, swapRB=True)
# Baking that into the CoreML model means Swift can hand it an image directly.
m = onnx2torch_convert("s/w600k_mbf.onnx").eval()

example = torch.rand(1, 3, 112, 112)
with torch.no_grad():
    ref = m(example)
print("torch output:", tuple(ref.shape))

traced = torch.jit.trace(m, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 112, 112),
                         scale=1/127.5, bias=[-1.0, -1.0, -1.0],
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.ALL,
)
mlmodel.short_description = "ArcFace (MobileFaceNet, w600k_mbf) face embedding, 512-d"
mlmodel.save("FaceEmbedding.mlpackage")
print("saved FaceEmbedding.mlpackage")
