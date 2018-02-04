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

sensorsPos_xVec = ...
    cfgStruct.physical.distanceBetweenSensors ...
    * ...
    (0:(cfgStruct.physical.nSensors-1));

sensorsPos_xVec = sensorsPos_xVec - mean(sensorsPos_xVec); % all sensors are on the x axis centered around 0

cfgStruct.physical.sensorsPos_xVec = sensorsPos_xVec;

f_getObjectDistance = ...
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
    f_getObjectDistance( ...             3. fminbnd returns the minimizero fo the function, now we fetch its value
    objCfg,...
    fminbnd(...
    @(t) ...                            2. combined steps 1-3 to a single function of objectDistance(t,objCfg)
    min(...
    cell2mat(...
    f_getObjectDistance( ...             1. fetch only the radious from the Spherical
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
f_getObjectDelay = @(objCfg,t) cellfun(@(distances) distances/propagationVelocity, f_getObjectDistance(objCfg,t,cfgStruct), 'UniformOutput',false);
discreteTVec = tSample*(0:(simDuration_Samples-1));

objSeperatedDelays_CELL = ...
    cellfun(...
    @(objCfg,t) ...
    f_getObjectDelay(...
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

for segmentId=1:simNSegments
    startSampleID           = (segmentId-1)*segmentSampleDuration+1;
    endSampleID             = segmentId*segmentSampleDuration;
    segmentDiscreteTVec     = ((startSampleID:endSampleID)-1)*tSample;
    
    segmentDelaysVec_CELL = ...
        cellfun(...
        @(objDelayVec_CELL) ...
        cellfun(...
        @(objDelayVec) ...
        reshape(objDelayVec(startSampleID:endSampleID),[],1), ...
        objDelayVec_CELL, ...
        'UniformOutput',false), ...
        objSeperatedDelays_CELL, ...
        'UniformOutput',false);
    
    segmentDelayedTimeVec_CELL = ...
        cellfun(...
        @(objDelayVec_CELL) ...
        cellfun(...
        @(objDelayVec) ...
        reshape(segmentDiscreteTVec(:)-objDelayVec(:),[],1), ...
        objDelayVec_CELL,...
        'UniformOutput',false), ...
        segmentDelaysVec_CELL, ...
        'UniformOutput',false);
    
    objectsNominalInput_CELL = ...
        cellfun( ...
        @(objCfg,objDelayedTime_CELL) ...
        cellfun( ...
        @(objDelayedTime) ...
        reshape(objCfg.sourceSignal(objDelayedTime),[],1), ...
        objDelayedTime_CELL, ...
        'UniformOutput', false), ...
        objCfgVec,segmentDelayedTimeVec_CELL, ...
        'UniformOutput',false);
    
    %%
    %{
In each segment, both the sensor inputs and eahc object's feedback
signal will be calculated and summed.
    %}
end
end