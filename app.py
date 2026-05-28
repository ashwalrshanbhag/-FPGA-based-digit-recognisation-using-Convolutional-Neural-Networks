from flask import Flask, render_template, request, jsonify
import numpy as np
from PIL import Image
import re, base64, io, time
import warnings
warnings.filterwarnings('ignore')

app = Flask(__name__)

# ── Try loading FPGA overlay ──────────────────────────────────────────────────
fpga_available = False
try:
    from pynq import Overlay
    from pynq import allocate
    overlay = Overlay("./modifieddesign_wrapper.bit")
    print("FPGA Overlay loaded!")
    print(dir(overlay))  # Print available IPs
    fpga_available = True
except Exception as e:
    print(f"FPGA not available: {e}")

# ── Pure NumPy CNN (CPU) ──────────────────────────────────────────────────────
def conv2d(x, weight, bias):
    N, C, H, W = x.shape
    F, C, kH, kW = weight.shape
    oH = H - kH + 1
    oW = W - kW + 1
    out = np.zeros((N, F, oH, oW), dtype=np.float32)
    for f in range(F):
        for i in range(oH):
            for j in range(oW):
                out[:, f, i, j] = (
                    np.sum(x[:, :, i:i+kH, j:j+kW] * weight[f], axis=(1,2,3))
                    + bias[f]
                )
    return out

def maxpool2d(x, kernel=2):
    N, C, H, W = x.shape
    oH, oW = H // kernel, W // kernel
    out = np.zeros((N, C, oH, oW), dtype=np.float32)
    for i in range(oH):
        for j in range(oW):
            out[:, :, i, j] = np.max(
                x[:, :, i*kernel:i*kernel+kernel,
                        j*kernel:j*kernel+kernel], axis=(2,3))
    return out

def relu(x):
    return np.maximum(0, x)

def log_softmax(x):
    x = x - np.max(x, axis=1, keepdims=True)
    return x - np.log(np.sum(np.exp(x), axis=1, keepdims=True))

def predict_cpu(x):
    x = conv2d(x, weights['conv1.weight'], weights['conv1.bias'])
    x = relu(maxpool2d(x))
    x = conv2d(x, weights['conv2.weight'], weights['conv2.bias'])
    x = relu(maxpool2d(x))
    x = x.reshape(1, -1)
    x = x @ weights['fc_1.weight'].T + weights['fc_1.bias']
    x = log_softmax(x)
    return int(np.argmax(x))

# ── FPGA inference (placeholder — update after checking overlay IPs) ──────────
def predict_fpga(x):
    try:
        from pynq import allocate
        
        # Input: 784 uint8 (0-255)
        input_data = (x.flatten() * 255).astype(np.uint8)
        
        in_buffer  = allocate(shape=(784,), dtype=np.uint8)
        out_buffer = allocate(shape=(1,),   dtype=np.uint8)  # ← 1 byte output!
        
        in_buffer[:]  = input_data
        out_buffer[:] = 0
        
        dma = overlay.axi_dma_0
        dma.sendchannel.transfer(in_buffer)
        dma.recvchannel.transfer(out_buffer)
        dma.sendchannel.wait()
        dma.recvchannel.wait()
        
        result = int(out_buffer[0])  # ← Direct digit, no argmax!
        print(f"FPGA raw output: {out_buffer[0]}, predicted: {result}")
        
        in_buffer.freebuffer()
        out_buffer.freebuffer()
        return result
        
    except Exception as e:
        print(f"FPGA inference error: {e}")
        return None
# ── Load weights ──────────────────────────────────────────────────────────────
def get_model():
    global weights
    data = np.load('./cnn_weights.npz')
    weights = {k: data[k] for k in data.files}
    print(" * Weights loaded OK")

# ── Timing history ────────────────────────────────────────────────────────────
timing_history = []

# ── Flask routes ──────────────────────────────────────────────────────────────
@app.route('/', methods=['GET'])
def index():
    return render_template('index.html')

@app.route('/', methods=['POST'])
def predict():
    base64str = request.get_json(force=True)['base64str']
    imgstr = re.search(r'base64,(.*)', str(base64str)).group(1)
    file = io.BytesIO(base64.b64decode(imgstr))
    img = Image.open(file).convert("L")
    img = img.resize((28, 28))
    im2arr = np.array(img).reshape(1, 1, 28, 28).astype(np.float32) / 255.0

    # CPU timing
    t0 = time.perf_counter()
    cpu_pred = predict_cpu(im2arr)
    cpu_time = round((time.perf_counter() - t0) * 1000, 3)  # ms

    # FPGA timing
    fpga_pred = None
    fpga_time = None
    if fpga_available:
        t1 = time.perf_counter()
        fpga_pred = predict_fpga(im2arr)
        fpga_time = round((time.perf_counter() - t1) * 1000, 3)

    # Store timing
    timing_history.append({
        'index': len(timing_history) + 1,
        'cpu_ms': cpu_time,
        'fpga_ms': fpga_time
    })

    return jsonify({
        'prediction': str(cpu_pred),
        'fpga_prediction': str(fpga_pred) if fpga_pred is not None else 'N/A',
        'cpu_time_ms': cpu_time,
        'fpga_time_ms': fpga_time,
        'timing_history': timing_history[-1:] 
    })

@app.route('/timing', methods=['GET'])
def timing():
    return jsonify(timing_history)

print(" * Loading weights...")
get_model()
print(" * Loading weights done")

if __name__ == '__main__':
    app.run(host='0.0.0.0')
