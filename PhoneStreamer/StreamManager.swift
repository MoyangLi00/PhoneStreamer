import Foundation
import SwiftUI
import Combine
import AVFoundation
import CoreMotion
import Network
import CoreImage
import CoreMedia
import simd
import UIKit

final class StreamManager: NSObject, ObservableObject {
    @Published var host: String = "192.168.0.0"
    @Published var port: UInt16 = 9999
    @Published var status: String = "Idle"
    @Published var frameCount: Int = 0
    @Published var imuCount: Int = 0

    private let motionManager = CMMotionManager()
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoQueue = DispatchQueue(label: "camera.video.queue")
    private let sendQueue = DispatchQueue(label: "network.send.queue")
    private let ciContext = CIContext()

    private var connection: NWConnection?
    private var isRunning = false

    private var activeDevice: AVCaptureDevice?
    private var cameraInfoSent = false
    private var focusLocked = false

    var previewSession: AVCaptureSession {
        captureSession
    }

    func start() {
        if isRunning { return }
        isRunning = true
        frameCount = 0
        imuCount = 0
        cameraInfoSent = false
        focusLocked = false

        connect()
        setupCamera()
        startRawIMU()

        DispatchQueue.main.async {
            self.status = "Starting..."
        }
    }

    func stop() {
        isRunning = false

        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()

        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }

        connection?.cancel()
        connection = nil

        DispatchQueue.main.async {
            self.status = "Stopped"
        }
    }

    // MARK: - Network

    private func connect() {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 9999
        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "Connected"
                case .failed(let error):
                    self?.status = "Connection failed: \(error.localizedDescription)"
                case .waiting(let error):
                    self?.status = "Waiting: \(error.localizedDescription)"
                case .cancelled:
                    self?.status = "Cancelled"
                default:
                    self?.status = "Connecting..."
                }
            }
        }

        conn.start(queue: sendQueue)
        self.connection = conn
    }

    private func sendPacket(type: UInt8, payload: Data) {
        guard let connection = connection else { return }

        var msg = Data()
        msg.append(type)
        msg.append(payload)

        var prefix = Data()
        prefix.appendUInt32(UInt32(msg.count))

        let full = prefix + msg

        connection.send(content: full, completion: .contentProcessed { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.status = "Send error: \(error.localizedDescription)"
                }
            }
        })
    }

    // MARK: - Camera

    private func setupCamera() {
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .hd1280x720

            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }
            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video,
                                                       position: .back) else {
                DispatchQueue.main.async {
                    self.status = "No back camera found"
                }
                self.captureSession.commitConfiguration()
                return
            }

            self.activeDevice = device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                output.setSampleBufferDelegate(self, queue: self.videoQueue)

                if self.captureSession.canAddOutput(output) {
                    self.captureSession.addOutput(output)
                }

                if let conn = output.connection(with: .video) {
                    if conn.isCameraIntrinsicMatrixDeliverySupported {
                        conn.isCameraIntrinsicMatrixDeliveryEnabled = true
                    }
                    if conn.isVideoRotationAngleSupported(0) {
                        conn.videoRotationAngle = 0
                    }
                }

                try device.lockForConfiguration()

                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }

                device.unlockForConfiguration()

                self.captureSession.commitConfiguration()
                self.captureSession.startRunning()

                DispatchQueue.main.async {
                    self.status = "Auto focusing..."
                }

                self.sessionQueue.asyncAfter(deadline: .now() + 1.0) {
                    self.lockFocusAtCurrentPosition()
                }

            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.status = "Camera setup failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func lockFocusAtCurrentPosition() {
        guard let device = activeDevice else { return }

        do {
            try device.lockForConfiguration()

            if device.isLockingFocusWithCustomLensPositionSupported {
                let pos = device.lensPosition
                device.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
                focusLocked = true

                DispatchQueue.main.async {
                    self.status = String(format: "Focus locked (lens=%.4f)", pos)
                }
            } else if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
                focusLocked = true

                DispatchQueue.main.async {
                    self.status = "Focus locked"
                }
            }

            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async {
                self.status = "Focus lock failed: \(error.localizedDescription)"
            }
        }
    }

    private func getIntrinsics(from sampleBuffer: CMSampleBuffer) -> simd_float3x3? {
        guard let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: sampleBuffer,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        ) as? [CFString: Any],
        let data = attachments[kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix] as? Data,
        data.count == MemoryLayout<matrix_float3x3>.size
        else {
            return nil
        }

        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: simd_float3x3.self)
        }
    }

    private func sendCameraInfoOnce(width: Int, height: Int, K: simd_float3x3, lensPosition: Float) {
        guard focusLocked else { return }
        guard !cameraInfoSent else { return }

        let fx = K[0, 0]
        let fy = K[1, 1]
        let cx = K[2, 0]
        let cy = K[2, 1]

        var payload = Data()
        payload.appendUInt32(UInt32(width))
        payload.appendUInt32(UInt32(height))
        payload.appendFloat(fx)
        payload.appendFloat(fy)
        payload.appendFloat(cx)
        payload.appendFloat(cy)
        payload.appendFloat(lensPosition)

        sendPacket(type: 3, payload: payload)
        cameraInfoSent = true

        DispatchQueue.main.async {
            self.status = String(
                format: "Dataset running | fx=%.1f fy=%.1f",
                fx, fy
            )
        }
    }

    // MARK: - Raw IMU

    private func startRawIMU() {
        if !motionManager.isAccelerometerAvailable {
            DispatchQueue.main.async {
                self.status = "Accelerometer not available"
            }
            return
        }

        if !motionManager.isGyroAvailable {
            DispatchQueue.main.async {
                self.status = "Gyro not available"
            }
            return
        }

        motionManager.accelerometerUpdateInterval = 1.0 / 100.0
        motionManager.gyroUpdateInterval = 1.0 / 100.0

        let accelQueue = OperationQueue()
        accelQueue.name = "accel.queue"

        let gyroQueue = OperationQueue()
        gyroQueue.name = "gyro.queue"

        motionManager.startAccelerometerUpdates(to: accelQueue) { [weak self] data, error in
            guard let self = self else { return }
            guard self.isRunning else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.status = "Accelerometer error: \(error.localizedDescription)"
                }
                return
            }

            guard let d = data else { return }

            let tNs = UInt64(max(0, d.timestamp) * 1e9)

            var payload = Data()
            payload.appendUInt64(tNs)
            payload.appendUInt8(0)
            payload.appendDouble(d.acceleration.x)
            payload.appendDouble(d.acceleration.y)
            payload.appendDouble(d.acceleration.z)

            self.sendPacket(type: 2, payload: payload)

            DispatchQueue.main.async {
                self.imuCount += 1
            }
        }

        motionManager.startGyroUpdates(to: gyroQueue) { [weak self] data, error in
            guard let self = self else { return }
            guard self.isRunning else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.status = "Gyro error: \(error.localizedDescription)"
                }
                return
            }

            guard let d = data else { return }

            let tNs = UInt64(max(0, d.timestamp) * 1e9)

            var payload = Data()
            payload.appendUInt64(tNs)
            payload.appendUInt8(1)
            payload.appendDouble(d.rotationRate.x)
            payload.appendDouble(d.rotationRate.y)
            payload.appendDouble(d.rotationRate.z)

            self.sendPacket(type: 2, payload: payload)

            DispatchQueue.main.async {
                self.imuCount += 1
            }
        }
    }
}

// MARK: - Video Delegate

extension StreamManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tNs = UInt64(max(0, CMTimeGetSeconds(pts)) * 1e9)

        if let K = getIntrinsics(from: sampleBuffer) {
            let lensPos = activeDevice?.lensPosition ?? -1.0
            sendCameraInfoOnce(width: width, height: height, K: K, lensPosition: lensPos)
        }

        // 只在锁焦后开始真正输出到数据集
        guard focusLocked else { return }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let cgImage = ciContext.createCGImage(ciImage, from: rect) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.6) else { return }

        var payload = Data()
        payload.appendUInt64(tNs)
        payload.appendUInt32(UInt32(width))
        payload.appendUInt32(UInt32(height))
        payload.appendUInt32(UInt32(jpegData.count))
        payload.append(jpegData)

        sendPacket(type: 1, payload: payload)

        DispatchQueue.main.async {
            self.frameCount += 1
        }
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendFloat(_ value: Float) {
        var v = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendDouble(_ value: Double) {
        var v = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
