@testset "PlanarLayer" begin
    # logpdf of a flow with a planar layer and two-dimensional inputs
    test_ad(randn(7)) do θ
        layer = PlanarLayer(θ[1:2], θ[3:4], θ[5:5])
        flow = transformed(MvNormal(zeros(2), I), layer)
        return logpdf_forward(flow, θ[6:7])
    end
    test_ad(randn(11)) do θ
        layer = PlanarLayer(θ[1:2], θ[3:4], θ[5:5])
        flow = transformed(MvNormal(zeros(2), I), layer)
        return sum(logpdf_forward(flow, reshape(θ[6:end], 2, :)))
    end

    # logpdf of a flow with the inverse of a planar layer and two-dimensional inputs
    test_ad(randn(7)) do θ
        layer = PlanarLayer(θ[1:2], θ[3:4], θ[5:5])
        flow = transformed(MvNormal(zeros(2), I), inv(layer))
        return logpdf_forward(flow, θ[6:7])
    end
    test_ad(randn(11)) do θ
        layer = PlanarLayer(θ[1:2], θ[3:4], θ[5:5])
        flow = transformed(MvNormal(zeros(2), I), inv(layer))
        return sum(logpdf_forward(flow, reshape(θ[6:end], 2, :)))
    end
end
