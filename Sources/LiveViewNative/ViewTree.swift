//
//  ViewTree.swift
// LiveViewNative
//
//  Created by Brian Cardarella on 4/23/21.
//

import Foundation
import SwiftUI
import LiveViewNativeCore

struct ViewTreeBuilder<R: RootRegistry> {
    func fromNodes(_ nodes: NodeChildrenSequence, coordinator: LiveViewCoordinator<R>, url: URL) -> some View {
        let context = LiveContextStorage(coordinator: coordinator, url: url)
        return fromNodes(nodes, context: context)
            .environment(\.anyLiveContextStorage, context)
    }
    
    @ViewBuilder
    func fromNodes<Nodes>(_ nodes: Nodes, context: LiveContextStorage<R>) -> some View
        where Nodes: RandomAccessCollection, Nodes.Index == Int, Nodes.Element == Node
    {
        forEach(nodes: nodes, context: context)
    }
    
    // alias for typing
    @inline(__always)
    fileprivate func f(_ n: Node, _ c: LiveContextStorage<R>) -> some View {
        return fromNode(n, context: c)
    }
    
    @ViewBuilder
    func fromNode(_ node: Node, context: LiveContextStorage<R>) -> some View {
        switch node.data {
        case .root:
            fatalError("ViewTreeBuilder.fromNode may not be called with the root node")
        case .leaf(let content):
            SwiftUI.Text(content)
        case .element(let element):
            fromElement(ElementNode(node: node, data: element), context: context)
        }
    }
    
    func fromElement(_ element: ElementNode, context: LiveContextStorage<R>) -> some View {
        let view = createView(element, context: context)

        let modified = view.applyModifiers(R.self)
        let bound = applyBindings(to: modified, element: element, context: context)
        let withID = applyID(element: element, to: bound)
        let withIDAndTag = applyTag(element: element, to: withID)

        return withIDAndTag
            .environment(\.element, element)
            .preference(key: _ProvidedBindingsKey.self, value: []) // reset for the next View.
    }

    @ViewBuilder
    private func applyID(element: ElementNode, to view: some View) -> some View {
        if let id = element.attributeValue(for: "id") {
            view.id(id)
        } else {
            view
        }
    }

    @ViewBuilder
    private func applyTag(element: ElementNode, to view: some View) -> some View {
        if let tag = element.attributeValue(for: "tag") {
            view.tag(Optional<String>.some(tag))
        } else {
            view
        }
    }
    
    @ViewBuilder
    private func createView(_ element: ElementNode, context: LiveContextStorage<R>) -> some View {
        if let tagName = R.TagName(rawValue: element.tag) {
            R.lookup(tagName, element: element)
        } else {
            BuiltinRegistry<R>.lookup(element.tag, element)
        } 
    }
    
    private func applyModifiers(encoded: String?, to view: some View, element: ElementNode, context: LiveContextStorage<R>) -> some View {
        let modifiers: [ModifierContainer<R>]
        if let encoded {
            let decoder = makeJSONDecoder()

            if let decoded = try? decoder.decode([ModifierContainer<R>].self, from: Data(encoded.utf8)) {
                modifiers = decoded
            } else {
                modifiers = []
            }
        } else {
            modifiers = []
        }
        return view.applyModifiers(modifiers[...], element: element, context: context)
    }
    
    @ViewBuilder
    private func applyBindings(
        to view: some View,
        element: ElementNode,
        context: LiveContextStorage<R>
    ) -> some View {
        view.applyBindings(
            element.attributes.filter({
                $0.name.rawValue.starts(with: "phx-") && $0.value != nil
            })[...],
            element: element,
            context: context
        )
    }
}

extension ViewTreeBuilder {
    enum Error: Swift.Error {
        case unknownModifierType
        
        var localizedDescription: String {
            switch self {
            case .unknownModifierType:
                return "The modifier type is not builtin and is not declared by the custom registry."
            }
        }
    }
}

extension CodingUserInfoKey {
    static var modifierAnimationScale: Self { .init(rawValue: "modifierAnimationScale")! }
}

enum ModifierContainer<R: RootRegistry>: Decodable {
    case builtin(BuiltinRegistry<R>.BuiltinModifier)
    case custom(R.CustomModifier)
    case error(ErrorModifier<R>)
    case inert
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if let type = R.ModifierType(rawValue: type) {
            do {
                self = .custom(try R.decodeModifier(type, from: decoder))
            } catch {
                self = .error(ErrorModifier<R>(type: type.rawValue, error: error))
            }
        } else if let type = BuiltinRegistry<R>.ModifierType(rawValue: type) {
            do {
                self = .builtin(try BuiltinRegistry<R>.decodeModifier(type, from: decoder))
            } catch {
                self = .error(ErrorModifier<R>(type: type.rawValue, error: error))
            }
        } else if ShapeModifierType(rawValue: type) != nil
                    || FinalShapeModifierType(rawValue: type) != nil
                    || TextModifierType(rawValue: type) != nil
                    || ImageModifierType(rawValue: type) != nil
        {
            self = .inert
        } else {
            self = .error(ErrorModifier<R>(type: type, error: ViewTreeBuilder<R>.Error.unknownModifierType))
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case type
    }
    
    @ViewModifierBuilder
    var modifier: some ViewModifier {
        switch self {
        case let .builtin(modifier):
            modifier
        case let .custom(modifier):
            modifier
        case let .error(modifier):
            modifier
        case .inert:
            EmptyModifier()
        }
    }
}

private struct ModifierObserver<Parent: View, R: RootRegistry>: View {
    let parent: Parent
    @ObservedElement private var element
    @LiveContext<R> private var context
    @Attribute("modifiers", transform: { attribute in
        guard let encoded = attribute?.value else { return [] }
        
        let decoder = makeJSONDecoder()
        
        guard let decoded = try? decoder.decode([ModifierContainer<R>].self, from: Data(encoded.utf8))
        else { return [] }
        
        return decoded
    }) private var modifiers: [ModifierContainer<R>]
    
    var body: some View {
        return parent
            .applyModifiers(modifiers[...], element: element, context: context.storage)
    }
}

// this view is required to to break the infinitely-recursive type that occurs if the body of this view is inlined into applyAttributes(_:context:)
private struct ModifierApplicator<Parent: View, R: RootRegistry>: View {
    let parent: Parent
    let modifiers: ArraySlice<ModifierContainer<R>>
    let element: ElementNode
    let context: LiveContextStorage<R>

    var body: some View {
        if modifiers.isEmpty {
            parent
        } else {
            ModifierApplicator<_, R>(
                // force-unwrap is okay, this view is never constructed with an empty slice
                parent: parent.modifier(modifiers.first!.modifier).environment(\.modifierChangeTrackingContext, ModifierChangeTrackingContext()),
                modifiers: modifiers.dropFirst(),
                element: element,
                context: context
            )
        }
    }
}

private struct BindingApplicator<Parent: View, R: RootRegistry>: View {
    let parent: Parent
    let bindings: ArraySlice<LiveViewNativeCore.Attribute>
    let element: ElementNode
    let context: LiveContextStorage<R>

    var body: some View {
        let remaining = bindings.dropFirst()
        // force-unwrap is okay, this view is never constructed with an empty slice
        let binding = bindings.first!
        BuiltinRegistry<R>.applyBinding(
            binding.name,
            event: binding.value!,
            value: element.buildPhxValuePayload(),
            to: parent,
            element: element
        )
        .applyBindings(remaining, element: element, context: context)
    }
}

extension View {
    func applyModifiers<R: RootRegistry>(_: R.Type = R.self) -> some View {
        ModifierObserver<Self, R>(parent: self)
    }
    
    @ViewBuilder
    func applyModifiers<R: RootRegistry>(_ modifiers: ArraySlice<ModifierContainer<R>>, element: ElementNode, context: LiveContextStorage<R>) -> some View {
        ModifierApplicator(parent: self, modifiers: modifiers, element: element, context: context)
    }
    
    @ViewBuilder
    func applyBindings<R: RootRegistry>(_ bindings: ArraySlice<LiveViewNativeCore.Attribute>, element: ElementNode, context: LiveContextStorage<R>) -> some View {
        if bindings.isEmpty {
            self
        } else {
            BindingApplicator(parent: self, bindings: bindings, element: element, context: context)
        }
    }
}

private enum ForEachElement: Identifiable {
    case keyed(Node, id: String)
    case unkeyed(Node)
    
    var id: String {
        switch self {
        case let .keyed(_, id):
            return id
        case let .unkeyed(node):
            return "\(node.id)"
        }
    }
}
// not fileprivate because List needs to use it so it has access to ForEach modifiers
func forEach<R: CustomRegistry>(nodes: some Collection<Node>, context: LiveContextStorage<R>) -> some DynamicViewContent {
    let elements = nodes.map { (node) -> ForEachElement in
        if let element = node.asElement(),
           let id = element.attributeValue(for: "id")
        {
            return .keyed(node, id: id)
        } else {
            return .unkeyed(node)
        }
    }
    return ForEach(elements) {
        switch $0 {
        case let .keyed(node, _),
             let .unkeyed(node):
            context.coordinator.builder.fromNode(node, context: context)
        }
    }
}

enum ForEachViewError: LocalizedError {
    case invalidNode
    case missingID
    
    var errorDescription: String? {
        switch self {
        case .invalidNode:
            return "node in list or parent with more than 10 children must be an element"
        case .missingID:
            return "element in list or parent with more than 10 children must have an id"
        }
    }
}
