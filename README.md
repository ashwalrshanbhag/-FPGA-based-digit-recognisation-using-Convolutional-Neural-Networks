## Training the Model

A small CNN was trained in PyTorch on the MNIST dataset — 60,000 grayscale images of handwritten digits (0–9), each 28×28 pixels. The network was kept deliberately lightweight so the same architecture could later be synthesised directly into FPGA hardware logic.

### Network Layers

* **Conv1:** 1 → 3 feature maps, 5×5 kernel → 24×24×3
* **MaxPool + ReLU:** 2×2 pooling → 12×12×3
* **Conv2:** 3 → 3 feature maps, 5×5 kernel → 8×8×3
* **MaxPool + ReLU:** 2×2 pooling → 4×4×3 (48 values)
* **Fully Connected:** 48 → 10 class scores → argmax gives predicted digit

Training runs for around 10 epochs and reaches roughly 96% accuracy on the test set. Because PyTorch has no stable 32-bit ARM build, it cannot be installed on the PYNQ-Z2 directly. Instead, the six weight tensors are extracted into a `.npz` numpy file using a small script, and the forward pass is re-implemented in pure numpy on the board for software (CPU) inference.

---

## Hardware Deployment on PYNQ-Z2

The PYNQ-Z2 board contains a ZYNQ-7000 SoC — a chip with two tightly coupled sides: the **Processing System (PS)**, an ARM Cortex-A9 CPU running Linux and Python, and the **Programmable Logic (PL)**, the FPGA fabric configured with a custom CNN accelerator.

### Vivado Block Design

All the Verilog modules shared above are synthesised in Vivado. After synthesising packing all our modules into an ip and then connected our ip with ZYNQ processing ip. Also an intermediate ip DMA was also added for better communication between Processor and the PL part of the PYNQ board. After the block diagram is done run implementation and generate bitstream to extract  `.bit` and `.hwh` files. PYNQ has a special feature of running Jupyter notebooks on its own processor, allowing us to send our generated `.bit` file and load the entire design onto the board using the `pynq.Overlay` library. Input data is then sent dynamically for hardware prediction.

Five IP blocks are wired together in Vivado to form a complete inference pipeline. Each one has a specific job:

<img width="1563" height="715" alt="Vivado Block Design" src="https://github.com/user-attachments/assets/84ffa50b-000d-49ad-8fa3-eee53ce66d8b" />

* **`processing_system7_0`**: The ARM CPU. Runs the Flask web app, preprocesses images, and controls the FPGA through two AXI ports — `GP0` for sending control commands and `HP0` for bulk data transfer. Also generates the 50 MHz clock that drives all PL logic.
* **`axi_dma_0`**: The data mover. Has two channels: `MM2S` reads 784 bytes from DDR and streams them to the CNN, while `S2MM` receives the 1-byte result from the CNN and writes it back to DDR.
* **`axis_cnn_mnist_0`**: The hardware CNN accelerator — the core of the project. All conv, pooling, and fully-connected layers run as programmable logic gates at 50 MHz. Weights are baked into the bitstream ROM at synthesis time. Accepts pixels one byte per clock, outputs the predicted digit as a single byte.
* **`axi_smc`**: Routes control signals from the ARM (`GP0` port) to the DMA so the CPU can program buffer addresses and issue start commands.
* **`axi_smc_hp0`**: A protocol bridge between the DMA and the `HP0` port on the PS, handling the AXI4-to-AXI3 conversion needed for high-speed bulk transfers.

### Signal Flow Through the Board
* **Control:** ARM → GP0 → axi_smc → DMA control registers *(start / stop)*
* **Data In:** DDR → HP0 → axi_smc_hp0 → DMA → CNN `s_axis` *(784 bytes in)*
* **Data Out:** CNN `m_axis` → DMA → axi_smc_hp0 → HP0 → DDR *(1 byte out)*

---

## What Happens When You Click Predict

<img width="1600" height="803" alt="Prediction Pipeline" src="https://github.com/user-attachments/assets/64fdf830-9f2d-4882-ad2a-6c7b3bf6f0ef" />

1.  The browser sends the drawn digit as a base64 image over HTTP POST to Flask on the ARM.
2.  Flask resizes it to 28×28, normalises to uint8, and stores the 784-byte array in DDR RAM.
3.  The ARM programs the DMA — sets the source address, length 784, and fires the start command.
4.  The DMA streams all 784 pixels one byte per clock into `axis_cnn_mnist_0` over AXI Stream.
5.  The hardware CNN runs the full pipeline in programmable logic. After 1,279 clock cycles (~25 µs of pure compute), the predicted digit is ready on the output stream.
6.  The DMA captures the 1-byte result and writes it to DDR. The ARM reads it and returns a JSON response to the browser.
7.  The web app shows both predictions side by side — CPU (~360 ms, numpy) and FPGA (~8 ms, hardware) — with a live bar chart and a speedup factor of around 42×.

### Hardware CNN Timing (inside `axis_cnn_mnist_0`)

A counter FSM sequences the pipeline. All weights are ROM constants — nothing is loaded at runtime.
* **Cycles 1 – 784:** Accept pixels, feed Conv1
* **Cycles 785 – 1278:** Pipeline runs automatically
* **Cycle 1279:** `m_axis_tvalid = HIGH` → result ready
* **Cycle 1280:** Reset, ready for next image

---

## Results

* **Software accuracy:** ~96%
* **Hardware accuracy:** ~90%
* **CPU inference:** ~360 ms (pure numpy on 32-bit ARM)
* **FPGA inference:** ~8 ms (hardware logic at 50 MHz)
* **Speedup:** ~42× faster than software
* **Pipeline length:** 1,280 clock cycles = 25.6 µs compute
