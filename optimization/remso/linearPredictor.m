function [ dx,dv ] = linearPredictor(du,x,u,v,ss,simVars,withAlgs)

[xs,vs,xd,vd,ax,dx,av,dv]  = condensing(x,u,v,ss,'simVars',simVars,...
    'uRightSeeds',du,...
    'computeCorrection',false,...
    'computeNullSpace',true,...
    'withAlgs',withAlgs);


end

