function [simOutput] = simulate_IIR_approx_singleScenario(cfgStruct)
%% init

%%
%{
First, the temporal positions of each object will be calculated.
%}
objCfgVec               = cfgStruct.scenario.objCfgVec;
cfgSimDuration          = cfgStruct.sim.simDuration;
f_objCartesian          = @(t,f_getCartesian) f_getCartesian(t);
f_objSphericalRadious   = @(objSpherical_CELL) ...
    cellfun(...
    @(objSpherical) objSpherical(:,1), ...
    objSpherical_CELL, ...
    'UniformOutput', false);

nSensors = cfgStruct.physical.nSensors;

sensorsPos_xVec = ...
    cfgStruct.physical.distanceBetweenSensors ...
    * ...
    (0:(nSensors-1));

sensorsPos_xVec = sensorsPos_xVec - mean(sensorsPos_xVec); % all sensors are on the x axis centered around 0

cfgStruct.physical.sensorsPos_xVec = sensorsPos_xVec;

f_getObjectDistance_CELL = ...
    @(objCfg,t,cfgStruct) ...
    f_objSphericalRadious( ...        3. fetch only the radious from the Spherical
    convCartesianToSpherical( ...     2. convert cartesian to Spherical
    genSensorPointers(...
    f_objCartesian( ...                 1. request catersian of an object in t
    t,objCfg.cartesianPosition ...
    ) ...
    ,cfgStruct ...
    ) ...
    ) ...
    );

minObjectDistance = ...
    min(...                             5. fetch the globally minimal object distance.
    cellfun( ...                        4. collect all minimal distances
    @(objCfg) ...
    min(...
    cell2mat(...
    f_getObjectDistance_CELL( ...             3. fminbnd returns the minimizero fo the function, now we fetch its value
    objCfg,...
    fminbnd(...
    @(t) ...                            2. combined steps 1-3 to a single function of objectDistance(t,objCfg)
    min(...
    cell2mat(...
    f_getObjectDistance_CELL( ...             1. fetch only the radious from the Spherical
    objCfg,t,cfgStruct ...
    ) ...
    ) ...
    ), ...
    0,cfgSimDuration ...
    ), ...                               fminbnd
    cfgStruct ...
    ) ...
    ) ...
    ),...
    objCfgVec ...    the cell array of objects
    ) ...
    );

%%
%{
The minimal distance to the sensors will determine the "tau_feedback".
%}
propagationVelocity = cfgStruct.physical.propagationVelocity;
minDelay_continious = minObjectDistance/propagationVelocity;    % this is the "tau_feedback"
tSample             = 1/cfgStruct.physical.fSample;
minDelay_samples    = floor(minDelay_continious/tSample);       % using floor to make sure the recursion is not compromised
minDelay            = minDelay_samples*tSample;                 % quantizing the min delay to avoid errors in the samples fetching
simNSegments        = ceil(cfgSimDuration/minDelay);
simDuration_Samples = simNSegments*minDelay_samples;
simDuration         = simDuration_Samples*tSample;

%%
%{
A delayed (by "tau_feedback") version of the objects positions will be
converted to delays.
These delays will serve as an offset from the current time when
fetching samples from the object's transmitters to the sensors inputs.
%}
f_getObjectRxDelay = ...
    @(objCfg,t) ...
    cellfun(...
    @(distances) ...
    distances/propagationVelocity, ...
    f_getObjectDistance_CELL(objCfg,t,cfgStruct), ...
    'UniformOutput',false);

discreteTVec = tSample*(0:(simDuration_Samples-1));

objSeperatedRxDelays_CELL = ...
    cellfun(...
    @(objCfg,t) ...
    f_getObjectRxDelay(...
    objCfg,...
    discreteTVec ... t
    ), ...
    objCfgVec,...
    'UniformOutput',false ...
    );

txPropagationVeclocity = cfgStruct.physical.txPropagationVeclocity;

f_getObjectFeedbackDelay = ...
    @(objCfg,t) ...
    cellfun(...
    @(distances) ...
    distances*(1/txPropagationVeclocity + 1/propagationVelocity), ...
    f_getObjectDistance_CELL(objCfg,t,cfgStruct), ...
    'UniformOutput',false);

objSeperatedFeedbackDelays_CELL = ...
    cellfun(...
    @(objCfg,t) ...
    f_getObjectFeedbackDelay(...
    objCfg,...
    discreteTVec ... t
    ), ...
    objCfgVec,...
    'UniformOutput',false ...
    );

%%
%{
The simulation will be segmented according to the minimal "tau_feedback"
so that each segment can be calculated indepedently due to the fact
that each sample in the segment depends only on "tau_feedback" delayed
signals.
%}
segmentSampleDuration = minDelay_samples;
arrayInput            = zeros(simDuration_Samples,nSensors);
arrayTx               = zeros(simDuration_Samples,nSensors);
xModulatorSignal      = sqrt(2)*cos(2*pi*cfgStruct.physical.modulatorFreq*discreteTVec);  
yModulatorSignal      = -sqrt(2)*sin(2*pi*cfgStruct.physical.modulatorFreq*discreteTVec);
lpfCoeffs             = genLPF(cfgStruct);

cfgStruct.filter.lpfCoeffs = lpfCoeffs;

assert(cfgStruct.physical.singleTransmitterFlag==1,'STILL NOT SUPPORTED');

objectsInput_CELL    = cell(1,nSensors);
objectsInput_CELL(:) = {zeros(simDuration_Samples,1)};


for segmentId=1:simNSegments
    startSampleID           = (segmentId-1)*segmentSampleDuration+1;
    endSampleID             = segmentId*segmentSampleDuration;
    segmentDiscreteTVec     = ((startSampleID:endSampleID)-1)*tSample;
    segmentModulatorX       = xModulatorSignal(startSampleID:endSampleID);
    segmentModulatorY       = yModulatorSignal(startSampleID:endSampleID);
    
    cfgStruct.dynamics.segmentId           = segmentId;
    cfgStruct.dynamics.startSampleID       = startSampleID;
    cfgStruct.dynamics.endSampleID         = endSampleID;
    cfgStruct.dynamics.segmentDiscreteTVec = segmentDiscreteTVec;
    cfgStruct.dynamics.segmentModulatorX   = segmentModulatorX;
    cfgStruct.dynamics.segmentModulatorY   = segmentModulatorY;
    
    segmentRxDelaysVec_CELL = ...
        cellfun(...
        @(objDelayVec_CELL) ... each object contributes
        cellfun(...
        @(objDelayVec) ... each object contributes differently to each sensor
        reshape(objDelayVec(startSampleID:endSampleID),[],1), ...
        objDelayVec_CELL, ...
        'UniformOutput',false), ...
        objSeperatedRxDelays_CELL, ...
        'UniformOutput',false);
    
    segmentFeedbackDelaysVec_CELL = ...
        cellfun(...
        @(objDelayVec_CELL) ... each object contributes
        cellfun(...
        @(objDelayVec) ... each object contributes differently to each sensor
        reshape(objDelayVec(startSampleID:endSampleID),[],1), ...
        objDelayVec_CELL, ...
        'UniformOutput',false), ...
        objSeperatedFeedbackDelays_CELL, ...
        'UniformOutput',false);
    
    segmentRxDelayedTimeVec_CELL = ...
        cellfun(...
        @(objDelayVec_CELL) ... each object contributes
        cellfun(...
        @(objDelayVec) ... each object contributes differently to each sensor
        reshape(segmentDiscreteTVec(:)-objDelayVec(:),[],1), ...
        objDelayVec_CELL,...
        'UniformOutput',false), ...
        segmentRxDelaysVec_CELL, ...
        'UniformOutput',false);
    
    segmentFeedbackDelayedTimeVec_CELL = ...
        cellfun(...
        @(objDelayVec_CELL) ... each object contributes
        cellfun(...
        @(objDelayVec) ... each object contributes differently to each sensor
        reshape(segmentDiscreteTVec(:)-objDelayVec(:),[],1), ...
        objDelayVec_CELL,...
        'UniformOutput',false), ...
        segmentFeedbackDelaysVec_CELL, ...
        'UniformOutput',false);
    
    segmentRxDelayedDistance_CELL = ...
        cellfun( ...
        @(objCfg,objDelayedTime_CELL) ... each object contributes
        cellfun( ...
        @(objDelayedTime,sensorId) ... each object contributes differently to each sensor
        getSignleCellValue(f_getObjectDistance_CELL(objCfg,objDelayedTime,cfgStruct),sensorId), ...
        objDelayedTime_CELL,...
        reshape(num2cell(1:nSensors),size(objDelayedTime_CELL)), ...
        'UniformOutput', false), ...
        objCfgVec,segmentRxDelayedTimeVec_CELL, ...
        'UniformOutput',false);
    
    segmentFeedbackDelayedDistance_CELL = ...
        cellfun( ...
        @(objCfg,objDelayedTime_CELL) ... each object contributes
        cellfun( ...
        @(objDelayedTime,sensorId) ... each object contributes differently to each sensor
        getSignleCellValue(f_getObjectDistance_CELL(objCfg,objDelayedTime,cfgStruct),sensorId), ...
        objDelayedTime_CELL,...
        reshape(num2cell(1:nSensors),size(objDelayedTime_CELL)), ...
        'UniformOutput', false), ...
        objCfgVec,segmentFeedbackDelayedTimeVec_CELL, ...
        'UniformOutput',false);
    
    objectsNominalInput_CELL = ...
        cellfun( ...
        @(objCfg,objDelayedTime_CELL,objDelayedDistance_CELL) ... each object contributes
        cellfun( ...
        @(objDelayedTime,objDelayedDistance) ... each object contributes differently to each sensor
        getAttenuation(objDelayedDistance,cfgStruct) ...
        .* ...
        reshape(objCfg.sourceSignal(objDelayedTime),[],1), ...
        objDelayedTime_CELL,objDelayedDistance_CELL, ...
        'UniformOutput', false), ...
        objCfgVec,segmentRxDelayedTimeVec_CELL,segmentRxDelayedDistance_CELL, ...
        'UniformOutput',false);
    
    segmentObjectsFeedback_CELL = ...
        cellfun( ...
        @(objCfg,objDelayedTime_CELL,objDelayedDistance_CELL) ... each object contributes
        cellfun( ...
        @(objDelayedTime,objDelayedDistance,sensorId) ... each object contributes differently to each sensor
        getAttenuation(objDelayedDistance,cfgStruct) ...
        .* ...
        sampleSignal((0:(endSampleID-1))*tSample,arrayTx(1:endSampleID,sensorId),objDelayedTime), ...
        objDelayedTime_CELL,objDelayedDistance_CELL,reshape(num2cell(1:nSensors),size(objDelayedTime_CELL)), ...
        'UniformOutput', false), ...
        objCfgVec,segmentFeedbackDelayedTimeVec_CELL,segmentFeedbackDelayedDistance_CELL, ...
        'UniformOutput',false);
    
    arrayNominalInput_stg1 = ... generate a single matrix for each object (nSamples x nSensros)
        cellfun(...
        @(objNominalInput) ...
        cell2mat(reshape(objNominalInput,1,[])), ...
        objectsNominalInput_CELL, ...
        'UniformOutput', false);
    
    arrayFeedbackInput_stg1 = ... generate a single matrix for each object (nSamples x nSensros)
        cellfun(...
        @(objFeedback) ...
        cell2mat(reshape(objFeedback,1,[])), ...
        segmentObjectsFeedback_CELL, ...
        'UniformOutput', false);
    
    arrayNominalInput = plus(arrayNominalInput_stg1{:}); % sum all objects contribution for each sensor seperatly
    arrayFeedback     = plus(arrayFeedbackInput_stg1{:});
    
    arrayInput(startSampleID:endSampleID,:) = ...
        arrayInput(startSampleID:endSampleID,:) ...
        + ...
        arrayNominalInput ...
        + ...
        cfgStruct.physical.enableFeedback ...
        * ...
        arrayFeedback;
    
    %%
    %{
    In each segment, both the sensor inputs and each object's feedback
    signal will be calculated and summed.
    %}    
    [segmentYOut,segmentArrayTx] = processor_goldenModel(arrayInput(startSampleID:endSampleID,:),cfgStruct);
    
    arrayTx(startSampleID:endSampleID,:) = segmentArrayTx;
    yOut(startSampleID:endSampleID,1)    = segmentYOut(:);    
end

simOutput.yOut = yOut;
end