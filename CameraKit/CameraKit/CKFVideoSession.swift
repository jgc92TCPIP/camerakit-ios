//
//  CKVideoSession.swift
//  CameraKit
//
//  Created by Adrian Mateoaea on 09/01/2019.
//  Copyright © 2019 Wonderkiln. All rights reserved.
//

import AVFoundation

extension CKFSession.FlashMode {
    
    var captureTorchMode: AVCaptureDevice.TorchMode {
        switch self {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
    }
}

@objc public class CKFVideoSession: CKFSession, AVCaptureFileOutputRecordingDelegate, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate {
    
    @objc public private(set) var isRecording = false
    
    let photoOutput = AVCapturePhotoOutput()
    
    @objc public var onFaceDetected: (() -> Void)?
    
    @objc public enum CameraDetectionVideo: UInt {
        case none, faces
    }
    
    @objc public var cameraDetection = CameraDetectionVideo.none {
        didSet {
            if oldValue == self.cameraDetection { return }
            
            for output in self.session.outputs {
                if output is AVCaptureMetadataOutput {
                    self.session.removeOutput(output)
                }
            }
            
            self.faceDetectionBoxes.forEach({ $0.removeFromSuperview() })
            self.faceDetectionBoxes = []
            
            if self.cameraDetection == .faces {
                let metadataOutput = AVCaptureMetadataOutput()
                self.session.addOutput(metadataOutput)
                
                metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                    metadataOutput.metadataObjectTypes = [.face]
                }
            }
        }
    }
    
    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let faceMetadataObjects = metadataObjects.filter({ $0.type == .face })
        
        if faceMetadataObjects.count > self.faceDetectionBoxes.count {
            for _ in 0..<faceMetadataObjects.count - self.faceDetectionBoxes.count {
                let view = UIView()
                view.layer.borderColor = UIColor.green.cgColor
                view.layer.borderWidth = 1
                self.overlayView?.addSubview(view)
                self.faceDetectionBoxes.append(view)
            }
        } else if faceMetadataObjects.count < self.faceDetectionBoxes.count {
            for _ in 0..<self.faceDetectionBoxes.count - faceMetadataObjects.count {
                self.faceDetectionBoxes.popLast()?.removeFromSuperview()
            }
        }
        
        for i in 0..<faceMetadataObjects.count {
            if let transformedMetadataObject = self.previewLayer?.transformedMetadataObject(for: faceMetadataObjects[i]) {
                self.faceDetectionBoxes[i].frame = transformedMetadataObject.bounds
            } else {
                self.faceDetectionBoxes[i].frame = CGRect.zero
            }
        }
        
        // Trigger the callback if a face is detected
        if !faceMetadataObjects.isEmpty {
            self.onFaceDetected?()
        }
    }

    var faceDetectionBoxes: [UIView] = []
    
    @objc public var cameraPosition = CameraPosition.back {
        didSet {
            do {
                let deviceInput = try CKFSession.captureDeviceInput(type: self.cameraPosition.deviceType)
                self.captureDeviceInput = deviceInput
            } catch let error {
                print(error.localizedDescription)
            }
        }
    }
    
    var captureDeviceInput: AVCaptureDeviceInput? {
        didSet {
            if let oldValue = oldValue {
                self.session.removeInput(oldValue)
            }
            
            if let captureDeviceInput = self.captureDeviceInput {
                self.session.addInput(captureDeviceInput)
            }
        }
    }
    
    @objc public override var zoom: Double {
        didSet {
            guard let device = self.captureDeviceInput?.device else {
                return
            }
            
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = CGFloat(self.zoom)
                device.unlockForConfiguration()
            } catch {
                //
            }
            
            if let delegate = self.delegate {
                delegate.didChangeValue(session: self, value: self.zoom, key: "zoom")
            }
        }
    }
    
    @objc public var flashMode = CKFSession.FlashMode.off {
        didSet {
            guard let device = self.captureDeviceInput?.device else {
                return
            }
            
            do {
                try device.lockForConfiguration()
                if device.isTorchModeSupported(self.flashMode.captureTorchMode) {
                    device.torchMode = self.flashMode.captureTorchMode
                }
                device.unlockForConfiguration()
            } catch {
                //
            }
        }
    }
    
    let movieOutput = AVCaptureMovieFileOutput()
    
    @objc public init(position: CameraPosition = .back) {
        super.init()
        
        defer {
            self.cameraPosition = position
            
            do {
                let microphoneInput = try CKFSession.captureDeviceInput(type: .microphone)
                self.session.addInput(microphoneInput)
            } catch let error {
                print(error.localizedDescription)
            }
        }
        
        self.session.sessionPreset = .hd1920x1080
        self.session.addOutput(self.movieOutput)
        
        // Photo Output
        if self.session.canAddOutput(photoOutput) {
            self.session.addOutput(photoOutput)
            // Configure your photoOutput settings if necessary
        }
    }
    
    // Capture photo
    @objc public func capturePhoto(completion: @escaping (UIImage?, Error?) -> Void) {
        let settings = AVCapturePhotoSettings()
        // Configure settings if needed, e.g., settings.flashMode = .auto

        photoOutput.capturePhoto(with: settings, delegate: self)
        self.photoCaptureCompletion = completion
    }

    // Keep a reference for the completion handler
    private var photoCaptureCompletion: ((UIImage?, Error?) -> Void)?

    @available(iOS 11.0, *)
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            photoCaptureCompletion?(nil, error)
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            photoCaptureCompletion?(nil, NSError(domain: "CKFVideoSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to retrieve image data"]))
            return
        }

        let image = UIImage(data: imageData)
        photoCaptureCompletion?(image, nil)
    }
    
    var recordCallback: (URL) -> Void = { (_) in }
    var errorCallback: (Error) -> Void = { (_) in }
    
    @objc public func record(url: URL? = nil, _ callback: @escaping (URL) -> Void, error: @escaping (Error) -> Void) {
        if self.isRecording { return }
        
        self.recordCallback = callback
        self.errorCallback = error
        
        let fileUrl: URL = url ?? {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            let fileUrl = paths[0].appendingPathComponent("output.mov")
            try? FileManager.default.removeItem(at: fileUrl)
            return fileUrl
        }()
        
        if let connection = self.movieOutput.connection(with: .video) {
            connection.videoOrientation = UIDevice.current.orientation.videoOrientation
        }
        
        self.movieOutput.startRecording(to: fileUrl, recordingDelegate: self)
    }
    
    @objc public func stopRecording() {
        if !self.isRecording { return }
        self.movieOutput.stopRecording()
    }
    
    @objc public func togglePosition() {
        self.cameraPosition = self.cameraPosition == .back ? .front : .back
    }
    
    @objc public func setWidth(_ width: Int, height: Int, frameRate: Int) {
        guard
            let input = self.captureDeviceInput,
            let format = CKFSession.deviceInputFormat(input: input, width: width, height: height, frameRate: frameRate)
        else {
            return
        }
        
        do {
            try input.device.lockForConfiguration()
            input.device.activeFormat = format
            input.device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            input.device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            input.device.unlockForConfiguration()
        } catch {
            //
        }
    }
    
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        self.isRecording = true
    }
    
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        self.isRecording = false
        
        defer {
            self.recordCallback = { (_) in }
            self.errorCallback = { (_) in }
        }
        
        if let error = error {
            self.errorCallback(error)
            return
        }
        
        self.recordCallback(outputFileURL)
    }
}
